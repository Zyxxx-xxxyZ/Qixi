#include "qixi/analysis_api.hpp"

#include <algorithm>
#include <cassert>
#include <optional>

namespace qixi::analysis {
namespace {

class CustomAnalysisEngine final : public AnalysisEngine {
public:
  explicit CustomAnalysisEngine(core::Evaluator* evaluator)
    : evaluator_(evaluator) {}

  const char* name() const override {
    return "custom";
  }

  bool loadLine(const GameLine& line, std::string* error) override {
    if(line.moves.size() > 400) {
      if(error) *error = "game line too long";
      return false;
    }
    line_ = line;
    line_.rules.komi = line.komi;
    core::AnalysisKey key;
    key.gameId = 1;
    key.modelId = core::ModelId::b6;
    key.rulesHash = core::hashRules(line_.rules);
    key.komiKey = core::komiToKey(line_.rules.komi);
    key.wideRootNoiseKey = core::wideRootNoiseToKey(0.0f);

    core::SearchParams params;
    params.cpuct = 1.1f;
    params.fpuValue = 0.0f;
    params.rootNoise = 0.0f;
    params.rootNoiseWeight = 0.0f;
    params.winLossUtilityFactor = 1.0f;
    params.staticScoreUtilityFactor = 0.0f;
    params.dynamicScoreUtilityFactor = 0.0f;
    params.seed = 0x4f52434c45ULL;

    store_ = core::MCTSStore::create(
      core::BoardLogic::emptyBoard(core::Color::black),
      line_.rules,
      key,
      params
    );
    store_->setEvaluator(evaluator_);
    rootNodeByPly_.clear();
    rootNodeByPly_.push_back(store_->currentRoot());

    // Materialize the full principal line as a visible path so every ply is a
    // reachable root without inventing side variations.
    for(size_t i = 0; i < line_.moves.size(); ++i) {
      const LineMove& lm = line_.moves[i];
      if(store_->rootBoard().nextPla != lm.pla) {
        if(error) *error = "side-to-move mismatch while loading line at ply " + std::to_string(i);
        return false;
      }
      const auto commit = store_->playMoveFromRoot(lm.move);
      if(!commit.ok) {
        if(error) *error = "illegal line move at ply " + std::to_string(i) + ": " + commit.error;
        return false;
      }
      store_->markVisible(commit.node, true);
      rootNodeByPly_.push_back(commit.node);
    }

    // Return to the start of the line.
    if(!store_->switchRoot(rootNodeByPly_[0], error))
      return false;
    currentPly_ = 0;
    additionalBudget_ = 0;
    return true;
  }

  bool setRootPly(size_t ply, std::string* error) override {
    if(!store_) {
      if(error) *error = "no line loaded";
      return false;
    }
    if(ply >= rootNodeByPly_.size()) {
      if(error) *error = "ply out of range";
      return false;
    }
    if(!store_->switchRoot(rootNodeByPly_[ply], error))
      return false;
    currentPly_ = ply;
    return true;
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
    if(!store_) {
      if(error) *error = "no line loaded";
      return 0;
    }
    if(evaluator_ == nullptr) {
      if(error) *error = "evaluator is null";
      return 0;
    }
    const uint64_t before = store_->snapshot().rootVisits;
    uint64_t executed = 0;
    for(uint64_t i = 0; i < additionalBudget_; ++i) {
      if(!store_->runPlayout())
        break;
      executed += 1;
    }
    const uint64_t after = store_->snapshot().rootVisits;
    // Root visits should increase by the number of successful playouts that
    // started at this root (every playout does).
    (void)before;
    (void)after;
    return executed;
  }

  uint64_t runAnalysesUntilTotal(uint64_t totalAnalyses, std::string* error) override {
    if(!store_) {
      if(error) *error = "no line loaded";
      return 0;
    }
    const uint64_t current = rootAnalysisCount();
    if(totalAnalyses <= current)
      return 0;
    additionalBudget_ = totalAnalyses - current;
    return runAnalyses(error);
  }

  uint64_t rootAnalysisCount() const override {
    if(!store_)
      return 0;
    return store_->snapshot().rootVisits;
  }

  RootObservation observeRoot() const override {
    RootObservation obs;
    if(!store_)
      return obs;
    const core::RootSnapshot snap = store_->snapshot();
    obs.analysisCount = snap.rootVisits;
    obs.winrate = snap.rootWinrate;
    obs.scoreLead = snap.rootScoreMean;
    obs.sideToMove = store_->rootBoard().nextPla;
    obs.label = "custom:ply=" + std::to_string(currentPly_);
    if(!snap.candidates.empty()) {
      obs.bestMove = snap.candidates.front().move;
      obs.bestMoveVisits = snap.candidates.front().visits;
    }
    return obs;
  }

  bool enableTestNnPolicyOnlySelection(uint64_t allowToken, std::string* error) override {
    if(!store_) {
      if(error) *error = "no line loaded";
      return false;
    }
    return store_->setTreeSelectionMode(
      core::TreeSelectionMode::testNnPolicyOnly,
      allowToken,
      error
    );
  }

  bool testNnPolicyOnlySelectionEnabled() const override {
    return store_ &&
      store_->treeSelectionMode() == core::TreeSelectionMode::testNnPolicyOnly;
  }

  bool memoryUnloadAndReload(std::string* error) override {
    if(!store_) {
      if(error) *error = "no line loaded";
      return false;
    }
    const bool wantPolicyOnly =
      store_->treeSelectionMode() == core::TreeSelectionMode::testNnPolicyOnly;
    const core::NodeId expectRoot = store_->currentRoot();
    const uint64_t visitsBefore = store_->snapshot().rootVisits;

    const auto mem = store_->memoryStats();
    const std::vector<uint8_t> bytes = store_->serialize();
    if(bytes.empty()) {
      if(error) {
        *error =
          "serialize produced empty blob (store too large or invalid; nodes=" +
          std::to_string(mem.nodeCount) + " actions=" + std::to_string(mem.actionCount) +
          " policyFloats=" + std::to_string(mem.policyFloatCount) +
          " ownershipFloats=" + std::to_string(mem.ownershipFloatCount) + ")";
      }
      return false;
    }

    // Drop live store (simulate memory unload).
    store_.reset();

    std::string importError;
    auto restored = core::MCTSStore::deserialize(bytes, &importError);
    if(!restored) {
      if(error) *error = "deserialize failed: " + importError;
      return false;
    }
    store_ = std::move(*restored);
    store_->setEvaluator(evaluator_);
    if(wantPolicyOnly) {
      if(!store_->setTreeSelectionMode(
           core::TreeSelectionMode::testNnPolicyOnly,
           core::MCTSStore::kTestSelectionModeAllowToken,
           error
         )) {
        return false;
      }
    }
    // Restore root view to the same node id (ids are preserved by serialize).
    if(expectRoot != store_->currentRoot()) {
      if(!store_->switchRoot(expectRoot, error))
        return false;
    }
    if(store_->snapshot().rootVisits != visitsBefore) {
      if(error) *error = "root visits changed across unload/reload";
      return false;
    }
    // currentPly_ and rootNodeByPly_ remain valid: NodeIds are stable across serialize.
    return true;
  }

private:
  core::Evaluator* evaluator_ = nullptr;
  GameLine line_{};
  std::optional<core::MCTSStore> store_;
  std::vector<core::NodeId> rootNodeByPly_;
  size_t currentPly_ = 0;
  uint64_t additionalBudget_ = 0;
};

} // namespace

std::unique_ptr<AnalysisEngine> createCustomAnalysisEngine(core::Evaluator* evaluator) {
  return std::make_unique<CustomAnalysisEngine>(evaluator);
}

} // namespace qixi::analysis
