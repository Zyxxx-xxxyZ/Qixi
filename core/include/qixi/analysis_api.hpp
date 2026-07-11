#pragma once

#include "qixi/mcts.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace qixi::analysis {

// Unified analysis backend API for:
//   - modified/custom persistent MCTS (qixi::core::MCTSStore)
//   - official KataGo Search (host-linked)
//
// Supports:
//   1. Root-changing operations along a fixed game line
//   2. Setting how many analyses (playouts/visits) to run next
//   3. Querying how many analyses the current root has received

struct RootObservation {
  // Analyses (visits) recorded on the current root node.
  uint64_t analysisCount = 0;

  // Win rate for the side to move at the root, in [0, 1].
  float winrate = 0.0f;

  // Expected score lead for the side to move ("points").
  float scoreLead = 0.0f;

  // Best candidate move by visit count (pass allowed).
  core::Move bestMove = core::kMovePass;
  uint64_t bestMoveVisits = 0;

  // Side to move at the current root.
  core::Color sideToMove = core::Color::black;

  // Optional human-readable label for logs.
  std::string label;
};

struct LineMove {
  core::Move move = core::kMovePass;
  core::Color pla = core::Color::black;
};

// Fixed principal line of play used as the universe of legal roots for a test.
// Index 0 is the empty/initial position; index k is the position after the first
// k moves of `moves` have been played.
struct GameLine {
  core::Rules rules{};
  std::vector<LineMove> moves;
  float komi = 7.5f;
};

class AnalysisEngine {
public:
  virtual ~AnalysisEngine() = default;

  // Human-readable backend name ("custom" / "official").
  virtual const char* name() const = 0;

  // Load a fixed game line. Clears prior search state and sets root to ply 0.
  virtual bool loadLine(const GameLine& line, std::string* error) = 0;

  // (1) Root-changing: set the root to the position after `ply` moves of the line.
  // ply must be in [0, line.moves.size()].
  virtual bool setRootPly(size_t ply, std::string* error) = 0;

  virtual size_t currentRootPly() const = 0;
  virtual size_t lineLength() const = 0;

  // (2) Set how many *additional* analyses (playouts) to run on the next runAnalyses().
  virtual void setAdditionalAnalyses(uint64_t count) = 0;
  virtual uint64_t additionalAnalysesBudget() const = 0;

  // Run the budgeted additional analyses from the current root.
  // Returns the number of analyses actually executed this call.
  virtual uint64_t runAnalyses(std::string* error) = 0;

  // Set an absolute total analysis count target for the current root, then run
  // until the root reaches that count (or no further progress is possible).
  // Used so the official backend can match the modified backend's observed total.
  virtual uint64_t runAnalysesUntilTotal(uint64_t totalAnalyses, std::string* error) = 0;

  // (3) Analyses performed on the node currently set as root.
  virtual uint64_t rootAnalysisCount() const = 0;

  // Root winrate, score lead (points), and best move.
  virtual RootObservation observeRoot() const = 0;

  // TEST-ONLY: select tree successors from the NN policy distribution alone
  // (ignore visit-dependent PUCT). Default implementation fails closed.
  // Active only when the linked core was built with
  // -DQIXI_ALLOW_TEST_SELECTION_MODES=1 and the allow token is correct.
  virtual bool enableTestNnPolicyOnlySelection(uint64_t allowToken, std::string* error) {
    if(error) {
      *error = "testNnPolicyOnly selection is not supported by this engine";
    }
    (void)allowToken;
    return false;
  }

  virtual bool testNnPolicyOnlySelectionEnabled() const {
    return false;
  }
};

// Factory for the modified/custom persistent MCTS backend.
// The engine does not own the evaluator; the caller must keep it alive.
std::unique_ptr<AnalysisEngine> createCustomAnalysisEngine(core::Evaluator* evaluator);

} // namespace qixi::analysis
