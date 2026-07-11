// Production core must refuse testNnPolicyOnly selection.
// Linked against qixi_core with QIXI_ALLOW_TEST_SELECTION_MODES=0.

#include "qixi/mcts.hpp"

#include <cassert>
#include <iostream>

using namespace qixi::core;

int main() {
  Rules rules;
  SearchParams params;
  AnalysisKey key;
  key.gameId = 1;
  key.modelId = ModelId::b6;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  UniformEvaluator eval;
  MCTSStore store = MCTSStore::create(BoardLogic::emptyBoard(Color::black), rules, key, params);
  store.setEvaluator(&eval);

  assert(store.treeSelectionMode() == TreeSelectionMode::puct);

  std::string err;
  const bool enabled = store.setTreeSelectionMode(
    TreeSelectionMode::testNnPolicyOnly,
    MCTSStore::kTestSelectionModeAllowToken,
    &err
  );
  assert(!enabled);
  assert(store.treeSelectionMode() == TreeSelectionMode::puct);
  assert(!err.empty());

  // puct remains settable.
  assert(store.setTreeSelectionMode(TreeSelectionMode::puct, 0, &err));

  std::cout << "qixi_policy_only_selection_prod_guard: ok (" << err << ")\n";
  return 0;
}
