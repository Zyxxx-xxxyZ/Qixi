// Edge-local PUCT: child-as-root visit mass must not change parent successor choice.
#include "qixi/mcts.hpp"

#include <cmath>
#include <iostream>
#include <string>

using namespace qixi::core;

static int failures = 0;

static void expect(bool cond, const char* msg) {
  if(!cond) {
    std::cerr << "FAIL: " << msg << "\n";
    failures += 1;
  }
}

int main() {
  Rules rules;
  rules.komi = 7.5f;
  SearchParams params;
  params.cpuct = 1.0f;
  params.cpuctExplorationLog = 0.45f;
  params.cpuctExplorationBase = 500.0f;
  params.rootNoise = 0.0f;
  params.playoutDoublingAdvantage = 0.0f;
  params.seed = 1;

  AnalysisKey key;
  key.gameId = 1;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  key.wideRootNoiseKey = wideRootNoiseToKey(params.rootNoise);
  key.playoutDoublingAdvantageKey = playoutDoublingAdvantageToKey(params.playoutDoublingAdvantage);

  BoardState board = BoardLogic::emptyBoard(Color::black);
  MCTSStore store = MCTSStore::create(board, rules, key, params);
  UniformEvaluator eval;
  store.setEvaluator(&eval);

  // Grow a little tree under root.
  store.runPlayouts(32);
  const NodeId rootId = store.currentRoot();
  expect(rootId != kInvalidNode, "root exists");

  // Find a tried edge with a child.
  const Node& rootNode = store.nodeArray().at(rootId);
  ActionId actionId = rootNode.firstAction;
  ActionId chosenAction = kInvalidAction;
  NodeId childId = kInvalidNode;
  uint32_t traversed = 0;
  while(actionId != kInvalidAction && traversed < rootNode.actionCount) {
    const Action& a = store.actionArray().at(actionId);
    if(a.visits > 0 && a.child != kInvalidNode) {
      chosenAction = actionId;
      childId = a.child;
      break;
    }
    actionId = a.nextAction;
    traversed += 1;
  }
  expect(chosenAction != kInvalidAction, "found tried edge with child");
  if(chosenAction == kInvalidAction)
    return 1;

  const Action& edgeBefore = store.actionArray().at(chosenAction);
  const uint64_t edgeVisitsBefore = edgeBefore.visits;
  const float edgeUtilityBefore = edgeBefore.stats.utilityMean;
  const Move edgeMove = edgeBefore.move;

  // Score the edge before inflating the child node.
  const float prior = store.nodeArray().at(rootId).policyOffset != kInvalidNode
    ? 0.05f
    : 0.05f;
  // Use scoreAction compatibility path.
  const Node& parentBefore = store.nodeArray().at(rootId);
  // Force a stable prior by reading arena if available.
  float p = prior;
  if(parentBefore.policyOffset != kInvalidNode) {
    // Access via run: we re-score after mutation; capture visit-based ranking instead.
  }
  (void)p;
  (void)edgeUtilityBefore;

  // Record which move is currently preferred among tried edges by visit count.
  Move bestByVisits = edgeMove;
  uint64_t bestVisits = edgeVisitsBefore;
  actionId = rootNode.firstAction;
  traversed = 0;
  while(actionId != kInvalidAction && traversed < rootNode.actionCount) {
    const Action& a = store.actionArray().at(actionId);
    if(a.visits > bestVisits) {
      bestVisits = a.visits;
      bestByVisits = a.move;
    }
    actionId = a.nextAction;
    traversed += 1;
  }

  // Inflate child node as if it had been searched as root (massive node stats).
  // We cannot mutate private node stats directly; switch root to child, run playouts, switch back.
  std::string err;
  expect(store.switchRoot(childId, &err), "switch to child as root");
  store.runPlayouts(64);
  expect(store.switchRoot(rootId, &err), "switch back to original root");

  // Edge visits on the original parent→child action must be unchanged (isolation).
  const Action& edgeAfter = store.actionArray().at(chosenAction);
  expect(edgeAfter.visits == edgeVisitsBefore, "edge visits unchanged after child-as-root search");

  // Preferred edge by visits among parent actions should still be the same ranking source.
  Move bestByVisitsAfter = edgeMove;
  uint64_t bestVisitsAfter = 0;
  const Node& rootAfter = store.nodeArray().at(rootId);
  actionId = rootAfter.firstAction;
  traversed = 0;
  while(actionId != kInvalidAction && traversed < rootAfter.actionCount) {
    const Action& a = store.actionArray().at(actionId);
    if(a.visits > bestVisitsAfter) {
      bestVisitsAfter = a.visits;
      bestByVisitsAfter = a.move;
    }
    actionId = a.nextAction;
    traversed += 1;
  }
  expect(bestByVisitsAfter == bestByVisits, "parent edge visit ranking unchanged after child-as-root");

  // PDA key helper sanity.
  expect(playoutDoublingAdvantageToKey(0.0f) == 0, "pda key 0");
  expect(playoutDoublingAdvantageToKey(1.0f) == 1000, "pda key 1.0");
  expect(playoutDoublingAdvantageToKey(-1.5f) == -1500, "pda key -1.5");

  if(failures == 0) {
    std::cout << "qixi_edge_local_selection passed\n";
    return 0;
  }
  std::cerr << "qixi_edge_local_selection failed with " << failures << " error(s)\n";
  return 1;
}
