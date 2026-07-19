#include "official_analysis_api.hpp"

#include "search/analysisdata.h"
#include "search/reportedsearchvalues.h"
#include "search/search.h"
#include "search/searchparams.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>

namespace qixi::oracle {
namespace {

Player qixiColorToPlayer(core::Color c) {
  if(c == core::Color::black)
    return P_BLACK;
  if(c == core::Color::white)
    return P_WHITE;
  return C_EMPTY;
}

Loc qixiMoveToLoc(core::Move move) {
  if(move == core::kMovePass)
    return Board::PASS_LOC;
  const core::Point p = core::moveToPoint(move);
  return Location::getLoc(p.x, p.y, 19);
}

core::Move locToQixiMove(Loc loc) {
  if(loc == Board::PASS_LOC || loc == Board::NULL_LOC)
    return core::kMovePass;
  return core::pointToMove(Location::getX(loc, 19), Location::getY(loc, 19));
}

Rules qixiRulesToKataGo(const core::Rules& rules) {
  Rules out = Rules::getTrompTaylorish();
  out.komi = rules.komi;
  switch(rules.koRule) {
    case core::KoRule::simple: out.koRule = Rules::KO_SIMPLE; break;
    case core::KoRule::positional: out.koRule = Rules::KO_POSITIONAL; break;
    case core::KoRule::situational: out.koRule = Rules::KO_SITUATIONAL; break;
  }
  switch(rules.scoringRule) {
    case core::ScoringRule::area: out.scoringRule = Rules::SCORING_AREA; break;
    case core::ScoringRule::territory: out.scoringRule = Rules::SCORING_TERRITORY; break;
  }
  out.multiStoneSuicideLegal = rules.multiStoneSuicideLegal;
  return out;
}

// Shared with custom analysis API so policy-only sampling keys match when both
// engines share the same seed and playout index scheme.
core::SearchParams makeAlignedTestSearchParams() {
  core::SearchParams params;
  params.cpuct = 1.1f;
  params.fpuValue = 0.0f;
  params.rootNoise = 0.0f;
  params.rootNoiseWeight = 0.0f;
  params.winLossUtilityFactor = 1.0f;
  params.staticScoreUtilityFactor = 0.0f;
  params.dynamicScoreUtilityFactor = 0.0f;
  params.seed = 0x4f52434c45ULL; // same as CustomAnalysisEngine
  return params;
}

class OfficialAnalysisEngine final : public analysis::AnalysisEngine {
public:
  explicit OfficialAnalysisEngine(HostNNContext* ctx) : ctx_(ctx), coreEval_(ctx) {
    assert(ctx_ != nullptr && ctx_->nnEval != nullptr);
    params_ = ctx_->baseParams;
    params_.numThreads = 1;
    params_.rootNoiseEnabled = false;
    params_.wideRootNoise = 0.0;
    params_.chosenMoveTemperature = 0.0;
    params_.chosenMoveTemperatureEarly = 0.0;
    params_.useLcbForSelection = false;
    search_ = std::make_unique<Search>(
      params_,
      ctx_->nnEval.get(),
      ctx_->logger.get(),
      "qixi-official-oracle"
    );
    search_->setAlwaysIncludeOwnerMap(true);
  }

  const char* name() const override {
    return testPolicyOnly_ ? "official-test-policy-only" : "official";
  }

  bool loadLine(const analysis::GameLine& line, std::string* error) override {
    try {
      line_ = line;
      line_.rules.komi = line.komi;
      kataRules_ = qixiRulesToKataGo(line_.rules);

      boards_.clear();
      histories_.clear();
      nextPlayers_.clear();

      Board board(19, 19);
      Player nextPla = P_BLACK;
      BoardHistory hist(board, nextPla, kataRules_, 0);
      boards_.push_back(board);
      histories_.push_back(hist);
      nextPlayers_.push_back(nextPla);

      for(size_t i = 0; i < line_.moves.size(); ++i) {
        const analysis::LineMove& lm = line_.moves[i];
        const Player pla = qixiColorToPlayer(lm.pla);
        const Loc loc = qixiMoveToLoc(lm.move);
        if(pla != nextPla) {
          if(error) *error = "official loadLine side-to-move mismatch at ply " + std::to_string(i);
          return false;
        }
        if(!hist.isLegal(board, loc, pla)) {
          if(error) *error = "official loadLine illegal move at ply " + std::to_string(i);
          return false;
        }
        hist.makeBoardMoveAssumeLegal(board, loc, pla, nullptr);
        nextPla = getOpp(pla);
        boards_.push_back(board);
        histories_.push_back(hist);
        nextPlayers_.push_back(nextPla);
      }

      search_->clearSearch();
      policyOnlyStore_.reset();
      additionalBudget_ = 0;
      if(!setRootPly(0, error))
        return false;
      return true;
    }
    catch(const std::exception& ex) {
      if(error) *error = std::string("official loadLine: ") + ex.what();
      return false;
    }
  }

  bool setRootPly(size_t ply, std::string* error) override {
    if(boards_.empty() || ply >= boards_.size()) {
      if(error) *error = "official setRootPly out of range";
      return false;
    }
    try {
      currentPly_ = ply;
      if(testPolicyOnly_) {
        // TEST-ONLY: non-persistent tree rebuilt to this ply (mirrors stock
        // setPosition clearing). Selection is NN-policy-only via MCTSStore.
        return rebuildPolicyOnlyStoreToPly(ply, error);
      }
      search_->setPosition(
        nextPlayers_[ply],
        boards_[ply],
        histories_[ply]
      );
      return true;
    }
    catch(const std::exception& ex) {
      if(error) *error = std::string("official setRootPly: ") + ex.what();
      return false;
    }
  }

  size_t currentRootPly() const override {
    return currentPly_;
  }

  size_t lineLength() const override {
    return line_.moves.size();
  }

  void setAdditionalAnalyses(uint64_t count) override {
    additionalBudget_ = count;
  }

  uint64_t additionalAnalysesBudget() const override {
    return additionalBudget_;
  }

  uint64_t runAnalyses(std::string* error) override {
    const uint64_t current = rootAnalysisCount();
    const uint64_t target = current + additionalBudget_;
    return runAnalysesUntilTotal(target, error);
  }

  uint64_t runAnalysesUntilTotal(uint64_t totalAnalyses, std::string* error) override {
    if(testPolicyOnly_)
      return runPolicyOnlyUntilTotal(totalAnalyses, error);
    return runOfficialPuctUntilTotal(totalAnalyses, error);
  }

  uint64_t rootAnalysisCount() const override {
    if(testPolicyOnly_) {
      if(!policyOnlyStore_)
        return 0;
      return policyOnlyStore_->snapshot().rootVisits;
    }
    if(search_ == nullptr)
      return 0;
    return static_cast<uint64_t>(std::max<int64_t>(0, search_->getRootVisits()));
  }

  analysis::RootObservation observeRoot() const override {
    if(testPolicyOnly_)
      return observePolicyOnlyRoot();
    return observeOfficialPuctRoot();
  }

  bool enableTestNnPolicyOnlySelection(uint64_t allowToken, std::string* error) override {
#if !defined(QIXI_ALLOW_TEST_SELECTION_MODES) || !QIXI_ALLOW_TEST_SELECTION_MODES
    if(error) {
      *error =
        "official test policy-only requires -DQIXI_ALLOW_TEST_SELECTION_MODES=1 "
        "(oracle must link qixi_core_testing)";
    }
    return false;
#else
    if(allowToken != core::MCTSStore::kTestSelectionModeAllowToken) {
      if(error) *error = "refusing official test policy-only without allow token";
      return false;
    }
    testPolicyOnly_ = true;
    // Rebuild current root under the test path so the next runAnalyses uses it.
    if(!boards_.empty()) {
      if(!rebuildPolicyOnlyStoreToPly(currentPly_, error))
        return false;
    }
    return true;
#endif
  }

  bool testNnPolicyOnlySelectionEnabled() const override {
    return testPolicyOnly_;
  }

  bool memoryUnloadAndReload(std::string* error) override {
    if(!testPolicyOnly_ || !policyOnlyStore_) {
      // Stock Search path has no Qixi store blob; no-op success under non-test mode.
      if(!testPolicyOnly_)
        return true;
      if(error) *error = "policy-only store not built for unload/reload";
      return false;
    }
    const bool wantPolicyOnly = true;
    const core::NodeId expectRoot = policyOnlyStore_->currentRoot();
    const uint64_t visitsBefore = policyOnlyStore_->snapshot().rootVisits;
    const std::vector<uint8_t> bytes = policyOnlyStore_->serialize();
    if(bytes.empty()) {
      if(error) *error = "official serialize produced empty blob";
      return false;
    }
    policyOnlyStore_.reset();
    std::string importError;
    auto restored = core::MCTSStore::deserialize(bytes, &importError);
    if(!restored) {
      if(error) *error = "official deserialize failed: " + importError;
      return false;
    }
    policyOnlyStore_ = std::move(*restored);
    policyOnlyStore_->setEvaluator(&coreEval_);
    if(wantPolicyOnly) {
#if defined(QIXI_ALLOW_TEST_SELECTION_MODES) && QIXI_ALLOW_TEST_SELECTION_MODES
      if(!policyOnlyStore_->setTreeSelectionMode(
           core::TreeSelectionMode::testNnPolicyOnly,
           core::MCTSStore::kTestSelectionModeAllowToken,
           error
         )) {
        return false;
      }
#endif
    }
    if(expectRoot != policyOnlyStore_->currentRoot()) {
      if(!policyOnlyStore_->switchRoot(expectRoot, error))
        return false;
    }
    if(policyOnlyStore_->snapshot().rootVisits != visitsBefore) {
      if(error) *error = "official root visits changed across unload/reload";
      return false;
    }
    return true;
  }

private:
  bool rebuildPolicyOnlyStoreToPly(size_t ply, std::string* error) {
    if(ply > line_.moves.size()) {
      if(error) *error = "policy-only rebuild ply out of range";
      return false;
    }
    core::AnalysisKey key;
    key.gameId = 1;
    key.modelId = core::ModelId::b6;
    key.rulesHash = core::hashRules(line_.rules);
    key.komiKey = core::komiToKey(line_.rules.komi);
    key.wideRootNoiseKey = core::wideRootNoiseToKey(0.0f);

    auto store = core::MCTSStore::create(
      core::BoardLogic::emptyBoard(core::Color::black),
      line_.rules,
      key,
      makeAlignedTestSearchParams()
    );
    store.setEvaluator(&coreEval_);
#if defined(QIXI_ALLOW_TEST_SELECTION_MODES) && QIXI_ALLOW_TEST_SELECTION_MODES
    if(!store.setTreeSelectionMode(
         core::TreeSelectionMode::testNnPolicyOnly,
         core::MCTSStore::kTestSelectionModeAllowToken,
         error
       )) {
      return false;
    }
#else
    if(error) *error = "policy-only store requires test selection modes";
    return false;
#endif

    // Replay only the principal line up to `ply` — no search state from other roots.
    for(size_t i = 0; i < ply; ++i) {
      const analysis::LineMove& lm = line_.moves[i];
      if(store.rootBoard().nextPla != lm.pla) {
        if(error) *error = "policy-only rebuild side-to-move mismatch";
        return false;
      }
      const auto commit = store.playMoveFromRoot(lm.move);
      if(!commit.ok) {
        if(error) *error = "policy-only rebuild illegal move: " + commit.error;
        return false;
      }
      store.markVisible(commit.node, true);
    }
    policyOnlyStore_ = std::move(store);
    return true;
  }

  uint64_t runPolicyOnlyUntilTotal(uint64_t totalAnalyses, std::string* error) {
    if(!policyOnlyStore_) {
      if(error) *error = "policy-only store not built";
      return 0;
    }
    const uint64_t before = policyOnlyStore_->snapshot().rootVisits;
    if(totalAnalyses <= before)
      return 0;
    const uint64_t need = totalAnalyses - before;
    uint64_t executed = 0;
    for(uint64_t i = 0; i < need; ++i) {
      if(!policyOnlyStore_->runPlayout())
        break;
      executed += 1;
    }
    return executed;
  }

  uint64_t runOfficialPuctUntilTotal(uint64_t totalAnalyses, std::string* error) {
    if(search_ == nullptr) {
      if(error) *error = "official search is null";
      return 0;
    }
    try {
      const uint64_t before = rootAnalysisCount();
      if(totalAnalyses <= before)
        return 0;

      SearchParams params = params_;
      params.numThreads = 1;
      params.maxVisits = static_cast<int64_t>(totalAnalyses);
      params.maxPlayouts = static_cast<int64_t>(totalAnalyses - before);
      params.maxTime = 1.0e20;
      search_->setParamsNoClearing(params);
      search_->setAlwaysIncludeOwnerMap(true);
      search_->runWholeSearch(nextPlayers_[currentPly_]);

      const uint64_t after = static_cast<uint64_t>(std::max<int64_t>(0, search_->getRootVisits()));
      if(after < before) {
        if(error) *error = "official root analysis count decreased after search";
        return 0;
      }
      return after - before;
    }
    catch(const std::exception& ex) {
      if(error) *error = std::string("official runAnalysesUntilTotal: ") + ex.what();
      return 0;
    }
  }

  analysis::RootObservation observePolicyOnlyRoot() const {
    analysis::RootObservation obs;
    if(!policyOnlyStore_)
      return obs;
    const core::RootSnapshot snap = policyOnlyStore_->snapshot();
    obs.analysisCount = snap.rootVisits;
    obs.winrate = snap.rootWinrate;
    obs.scoreLead = snap.rootScoreMean;
    obs.sideToMove = policyOnlyStore_->rootBoard().nextPla;
    obs.label = "official-test-policy-only:ply=" + std::to_string(currentPly_);
    if(!snap.candidates.empty()) {
      obs.bestMove = snap.candidates.front().move;
      obs.bestMoveVisits = snap.candidates.front().visits;
    }
    return obs;
  }

  analysis::RootObservation observeOfficialPuctRoot() const {
    analysis::RootObservation obs;
    if(search_ == nullptr)
      return obs;
    obs.analysisCount = rootAnalysisCount();
    obs.sideToMove = nextPlayers_[currentPly_] == P_BLACK ? core::Color::black : core::Color::white;
    obs.label = "official:ply=" + std::to_string(currentPly_);

    ReportedSearchValues values;
    if(search_->getRootValues(values)) {
      const double whiteWinrate = 0.5 * (1.0 + values.winLossValue);
      if(obs.sideToMove == core::Color::white) {
        obs.winrate = static_cast<float>(whiteWinrate);
        obs.scoreLead = static_cast<float>(values.expectedScore);
      } else {
        obs.winrate = static_cast<float>(1.0 - whiteWinrate);
        obs.scoreLead = static_cast<float>(-values.expectedScore);
      }
    }

    std::vector<AnalysisData> buf;
    search_->getAnalysisData(buf, 1, false, 1, false);
    if(!buf.empty()) {
      obs.bestMove = locToQixiMove(buf[0].move);
      obs.bestMoveVisits = static_cast<uint64_t>(std::max<int64_t>(0, buf[0].numVisits));
    }
    return obs;
  }

  HostNNContext* ctx_ = nullptr;
  HostCoreEvaluator coreEval_;
  SearchParams params_{};
  std::unique_ptr<Search> search_;
  std::optional<core::MCTSStore> policyOnlyStore_;
  bool testPolicyOnly_ = false;
  analysis::GameLine line_{};
  Rules kataRules_{};
  std::vector<Board> boards_;
  std::vector<BoardHistory> histories_;
  std::vector<Player> nextPlayers_;
  size_t currentPly_ = 0;
  uint64_t additionalBudget_ = 0;
};

} // namespace

std::unique_ptr<analysis::AnalysisEngine> createOfficialAnalysisEngine(HostNNContext* ctx) {
  return std::make_unique<OfficialAnalysisEngine>(ctx);
}

} // namespace qixi::oracle
