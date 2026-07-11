#include "qixi/mcts.hpp"

#include <cassert>
#include <iostream>

using namespace qixi::core;

namespace {

AnalysisKey makeKey() {
  Rules rules;
  AnalysisKey key;
  key.gameId = 7;
  key.modelId = ModelId::b6;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  key.wideRootNoiseKey = 0;
  return key;
}

} // namespace

int main() {
  Rules rules;
  SearchParams params;
  params.rootNoise = 0.0f;
  UniformEvaluator eval;
  MCTSStore store = MCTSStore::create(BoardLogic::emptyBoard(Color::black), rules, makeKey(), params);
  store.setEvaluator(&eval);

  // Build a short principal line: ply0 --B--> ply1 --W--> ply2
  const Move b1 = pointToMove(3, 3);
  const Move w1 = pointToMove(15, 15);
  assert(store.playMoveFromRoot(b1).ok);
  const NodeId n1 = store.currentRoot();
  assert(store.playMoveFromRoot(w1).ok);
  const NodeId n2 = store.currentRoot();
  assert(store.nodeArray()[n2].ply == 2);

  // Switch to empty root and search so that playouts can reach descendants.
  assert(store.switchRoot(0, nullptr));
  assert(store.nodeArray()[0].ply == 0);
  store.runPlayouts(64);
  assert(store.rootHasVisitedNode(0));
  // After searching from the ancestor root, the root itself is labeled at depth 0.
  assert(store.nodeArray()[0].minVisitedRootDepth == 0);

  // Ensure principal children are present and expanded along some path by playing
  // and searching from n1 as root.
  assert(store.switchRoot(n1, nullptr));
  assert(store.nodeArray()[n1].ply == 1);
  // Before any search at n1, if n1 was never a first-visit leaf under a root at
  // depth <= 1, it may still be unvisited at this root.
  const bool n1VisitedBefore = store.rootHasVisitedNode(n1);
  store.runPlayouts(32);
  assert(store.rootHasVisitedNode(n1));
  assert(store.nodeArray()[n1].minVisitedRootDepth <= 1);
  assert(store.nodeArray()[n1].hasStoredNN || store.nodeArray()[n1].state == NodeState::expanded);

  // Deeper root n2: if an ancestor with smaller depth already visited a node on
  // the path, inheritance says deeper root has visited when d_deep >= d_min.
  assert(store.switchRoot(n2, nullptr));
  // n2 itself needs its own first visit unless already labeled with d_min <= 2.
  store.runPlayouts(16);
  assert(store.rootHasVisitedNode(n2));
  assert(store.nodeArray()[n2].minVisitedRootDepth <= 2);

  // Isolation of labels: searching at n2 must not claim that root-0 visited n2
  // unless d_min(n2) <= 0.
  assert(store.switchRoot(0, nullptr));
  if(store.nodeArray()[n2].minVisitedRootDepth > 0) {
    assert(!store.rootHasVisitedNode(n2));
  } else {
    // Only if some root at depth 0 actually visited n2.
    assert(store.rootHasVisitedNode(n2));
  }

  // Shallower root must still be able to first-visit a node that only a deeper
  // root labeled: force a fresh branch under root 0.
  // Create sibling of n1 by switching to 0 and playing a different first move.
  assert(store.switchRoot(0, nullptr));
  const Move bAlt = pointToMove(2, 3);
  assert(store.playMoveFromRoot(bAlt).ok);
  const NodeId nAlt = store.currentRoot();
  assert(store.nodeArray()[nAlt].ply == 1);
  assert(store.nodeArray()[nAlt].minVisitedRootDepth == kNeverVisitedRootDepth);
  assert(!store.rootHasVisitedNode(nAlt)); // still at nAlt as root, not yet searched
  store.runPlayouts(8);
  assert(store.rootHasVisitedNode(nAlt));
  assert(store.nodeArray()[nAlt].minVisitedRootDepth == 1);
  assert(store.nodeArray()[nAlt].hasStoredNN);

  // Switch to ancestor: ancestor has depth 0 < 1, so has NOT visited nAlt.
  assert(store.switchRoot(0, nullptr));
  assert(!store.rootHasVisitedNode(nAlt));
  // Searching from ancestor must be allowed to first-visit nAlt (and reuse NN).
  store.runPlayouts(8);
  // After ancestor search, if selection reached nAlt, min depth becomes 0.
  // Not guaranteed in 8 playouts with huge branching; at least the predicate
  // remained consistent before search.
  (void)n1VisitedBefore;

  // Stored NN survives root switches.
  assert(store.switchRoot(nAlt, nullptr));
  assert(store.nodeArray()[nAlt].hasStoredNN);

  std::cout << "qixi_min_root_depth_visits: ok\n";
  return 0;
}
