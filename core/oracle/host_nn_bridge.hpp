#pragma once

// Host-side KataGo NNEvaluator adapter for the custom qixi::core::Evaluator.
// Lives outside pure qixi_core so core unit tests do not require KataGo.

#include "qixi/mcts.hpp"

#include "core/config_parser.h"
#include "core/logger.h"
#include "core/rand.h"
#include "game/board.h"
#include "game/boardhistory.h"
#include "game/rules.h"
#include "neuralnet/nneval.h"
#include "neuralnet/nninputs.h"
#include "program/setup.h"
#include "search/searchparams.h"

#include <memory>
#include <string>

namespace qixi::oracle {

struct HostNNContext {
  std::unique_ptr<ConfigParser> cfg;
  std::unique_ptr<Logger> logger;
  Rand seedRand;
  std::unique_ptr<NNEvaluator> nnEval;
  SearchParams baseParams;
  std::string modelPath;
};

// Initialize process-wide KataGo tables once.
void initKataGoProcessOnce();

// Create NN evaluator with numSearchThreads=1 and analysis-oriented params.
// Returns nullptr and sets *error on failure.
std::unique_ptr<HostNNContext> createHostNNContext(
  const std::string& modelPath,
  std::string* error
);

// Convert qixi board/rules into KataGo Board + BoardHistory + next player.
bool buildKataGoPosition(
  const core::BoardState& state,
  const core::Rules& rules,
  Board& board,
  BoardHistory& history,
  Player& nextPlayer,
  std::string* error
);

// Custom-core evaluator that calls the shared NNEvaluator (skipCache, with ownership).
class HostCoreEvaluator final : public core::Evaluator {
public:
  explicit HostCoreEvaluator(HostNNContext* ctx);

  bool evaluate(
    const core::BoardState& board,
    const core::Rules& rules,
    bool isRoot,
    core::LeafPayload& output
  ) override;

private:
  HostNNContext* ctx_ = nullptr;
  NNResultBuf resultBuf_;
};

} // namespace qixi::oracle
