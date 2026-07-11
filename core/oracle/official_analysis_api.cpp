#include "official_analysis_api.hpp"

#include "search/analysisdata.h"
#include "search/reportedsearchvalues.h"
#include "search/search.h"
#include "search/searchparams.h"

#include <algorithm>
#include <cmath>
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

class OfficialAnalysisEngine final : public analysis::AnalysisEngine {
public:
  explicit OfficialAnalysisEngine(HostNNContext* ctx) : ctx_(ctx) {
    assert(ctx_ != nullptr && ctx_->nnEval != nullptr);
    params_ = ctx_->baseParams;
    params_.numThreads = 1;
    params_.rootNoiseEnabled = false;
    params_.wideRootNoise = 0.0;
    params_.chosenMoveTemperature = 0.0;
    params_.chosenMoveTemperatureEarly = 0.0;
    params_.useLcbForSelection = false;
    // Deterministic-ish search seed.
    search_ = std::make_unique<Search>(
      params_,
      ctx_->nnEval.get(),
      ctx_->logger.get(),
      "qixi-official-oracle"
    );
    search_->setAlwaysIncludeOwnerMap(true);
    // Keep stock official Search (persistent MCTS left OFF — see header note).
    search_->setPersistentMCTSEnabled(false);
  }

  const char* name() const override {
    return "official";
  }

  bool loadLine(const analysis::GameLine& line, std::string* error) override {
    try {
      line_ = line;
      line_.rules.komi = line.komi;
      kataRules_ = qixiRulesToKataGo(line_.rules);

      // Build position snapshots for every ply along the principal line.
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

      // Fresh official tree for this line.
      search_->clearSearch();
      if(!setRootPly(0, error))
        return false;
      additionalBudget_ = 0;
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
      // Standard official root change: install position and clear prior search tree.
      search_->setPosition(
        nextPlayers_[ply],
        boards_[ply],
        histories_[ply]
      );
      currentPly_ = ply;
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
      // Absolute visit target for this root; playout budget is the remainder.
      params.maxVisits = static_cast<int64_t>(totalAnalyses);
      params.maxPlayouts = static_cast<int64_t>(totalAnalyses - before);
      // Keep search time unlimited so visit caps dominate.
      params.maxTime = 1.0e20;
      search_->setParamsNoClearing(params);
      search_->setAlwaysIncludeOwnerMap(true);
      search_->runWholeSearch(nextPlayers_[currentPly_]);

      const uint64_t after = rootAnalysisCount();
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

  uint64_t rootAnalysisCount() const override {
    if(search_ == nullptr)
      return 0;
    return static_cast<uint64_t>(std::max<int64_t>(0, search_->getRootVisits()));
  }

  analysis::RootObservation observeRoot() const override {
    analysis::RootObservation obs;
    if(search_ == nullptr)
      return obs;
    obs.analysisCount = rootAnalysisCount();
    obs.sideToMove = nextPlayers_[currentPly_] == P_BLACK ? core::Color::black : core::Color::white;
    obs.label = "official:ply=" + std::to_string(currentPly_);

    ReportedSearchValues values;
    if(search_->getRootValues(values)) {
      // winLossValue is white-centric (-1..1). Convert to side-to-move winrate.
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

private:
  HostNNContext* ctx_ = nullptr;
  SearchParams params_{};
  std::unique_ptr<Search> search_;
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
