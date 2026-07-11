// Validates test-only NN-policy selection (visit-independent).
// Linked against qixi_core_testing (QIXI_ALLOW_TEST_SELECTION_MODES=1).

#include "qixi/mcts.hpp"

#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

using namespace qixi::core;

namespace {

// Fixed policy: only three board moves have mass; visits must not change choice.
class FixedPolicyEvaluator final : public Evaluator {
public:
  Move forcedTop = pointToMove(3, 3);
  Move forcedSecond = pointToMove(4, 4);
  Move forcedThird = pointToMove(5, 5);

  bool evaluate(const BoardState&, const Rules&, bool, LeafPayload& output) override {
    output = LeafPayload{};
    output.winLossWhite = 0.1f;
    output.scoreMeanWhite = 1.0f;
    output.scoreMeanSqWhite = 1.0f;
    output.leadWhite = 1.0f;
    output.utilityWhite = 0.1f;
    output.weight = 1.0f;
    output.policy.fill(-1.0f);
    // Normalized over the three supported moves (others illegal via -1).
    // Actually expand uses legal mask — empty board all empty points legal.
    // Put mass only on three moves; rest get tiny equal residual for legality.
    float residual = 1.0e-6f;
    for(int i = 0; i < kMoveCount; ++i)
      output.policy[i] = residual;
    output.policy[forcedTop] = 0.70f;
    output.policy[forcedSecond] = 0.20f;
    output.policy[forcedThird] = 0.09f;
    // renorm is done in expandNode over legal moves
    for(int i = 0; i < kOwnershipDim; ++i)
      output.ownership[i] = 0.0f;
    return true;
  }
};

AnalysisKey makeKey() {
  Rules rules;
  AnalysisKey key;
  key.gameId = 42;
  key.modelId = ModelId::b6;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  return key;
}

Move topChildMove(const MCTSStore& store, NodeId parent) {
  Move best = kMovePass;
  uint64_t bestVisits = 0;
  bool found = false;
  for(const Action& a : store.actionArray()) {
    if(a.parent != parent)
      continue;
    if(!found || a.visits > bestVisits || (a.visits == bestVisits && a.move < best)) {
      best = a.move;
      bestVisits = a.visits;
      found = true;
    }
  }
  return best;
}

} // namespace

int main() {
  Rules rules;
  SearchParams params;
  params.seed = 0xDEADBEEFCAFEull;
  params.cpuct = 1.1f;
  params.rootNoise = 0.0f;
  FixedPolicyEvaluator eval;
  MCTSStore store = MCTSStore::create(BoardLogic::emptyBoard(Color::black), rules, makeKey(), params);
  store.setEvaluator(&eval);

  // Default is PUCT.
  assert(store.treeSelectionMode() == TreeSelectionMode::puct);

  std::string err;
  assert(store.setTreeSelectionMode(
    TreeSelectionMode::testNnPolicyOnly,
    MCTSStore::kTestSelectionModeAllowToken,
    &err
  ));
  assert(store.treeSelectionMode() == TreeSelectionMode::testNnPolicyOnly);

  // Wrong token must fail and leave/restore safe mode behavior.
  assert(!store.setTreeSelectionMode(
    TreeSelectionMode::testNnPolicyOnly,
    /*bad*/ 0,
    &err
  ));
  // After failed enable with wrong token, mode is forced back to puct.
  assert(store.treeSelectionMode() == TreeSelectionMode::puct);
  assert(store.setTreeSelectionMode(
    TreeSelectionMode::testNnPolicyOnly,
    MCTSStore::kTestSelectionModeAllowToken,
    &err
  ));

  // Expand root so policy is stored.
  assert(store.runPlayout());
  assert(store.nodeArray()[store.currentRoot()].state == NodeState::expanded);
  assert(store.nodeArray()[store.currentRoot()].hasStoredNN);

  // Run many playouts. Under pure NN-policy selection, the empirical child
  // distribution should track the fixed priors — NOT be dominated by early
  // visit amplification the way PUCT does.
  store.runPlayouts(400);
  const NodeId root = store.currentRoot();
  uint64_t vTop = 0, vSecond = 0, vThird = 0, vOther = 0;
  for(const Action& a : store.actionArray()) {
    if(a.parent != root)
      continue;
    if(a.move == eval.forcedTop)
      vTop += a.visits;
    else if(a.move == eval.forcedSecond)
      vSecond += a.visits;
    else if(a.move == eval.forcedThird)
      vThird += a.visits;
    else
      vOther += a.visits;
  }
  const uint64_t total = vTop + vSecond + vThird + vOther;
  assert(total >= 300);
  // Top prior move should receive the plurality of edge visits.
  assert(vTop > vSecond);
  assert(vTop > vThird);
  // Residual moves may get a few samples from renormalization; keep them small.
  assert(vOther * 5 < vTop);

  // After heavy visits on top move, re-seed a fresh store with PUCT and the same
  // evaluator: PUCT will still eventually prefer good Q, but the key property
  // of policy-only is visit-independence of *selection* at equal priors path.
  // Smoke: disabling returns to puct.
  assert(store.setTreeSelectionMode(TreeSelectionMode::puct, 0, &err));
  assert(store.treeSelectionMode() == TreeSelectionMode::puct);

  std::cout << "qixi_policy_only_selection: ok"
            << " vTop=" << vTop
            << " vSecond=" << vSecond
            << " vThird=" << vThird
            << " vOther=" << vOther
            << "\n";
  return 0;
}
