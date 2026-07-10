#include "qixi/request_pool.hpp"

#include <cassert>
#include <cmath>
#include <iostream>
#include <random>
#include <set>
#include <vector>

using namespace qixi::core;

namespace {

AnalysisKey makeKey(GameId gameId, ModelId modelId, const Rules& rules, int32_t noiseKey = 0) {
  AnalysisKey key;
  key.gameId = gameId;
  key.modelId = modelId;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  key.wideRootNoiseKey = noiseKey;
  return key;
}

bool sameStats(const ScalarStats& a, const ScalarStats& b) {
  return a.weightSum == b.weightSum &&
    a.weightSqSum == b.weightSqSum &&
    a.winLossMeanWhite == b.winLossMeanWhite &&
    a.noResultMean == b.noResultMean &&
    a.scoreMeanWhite == b.scoreMeanWhite &&
    a.scoreMeanSqWhite == b.scoreMeanSqWhite &&
    a.leadMeanWhite == b.leadMeanWhite &&
    a.utilityMean == b.utilityMean &&
    a.utilitySqMean == b.utilitySqMean;
}

void testHistorySensitiveLineage() {
  Rules rules;
  BoardState direct = BoardLogic::emptyBoard(Color::black);
  BoardState afterPasses = direct;
  auto passOne = BoardLogic::playMove(afterPasses, rules, kMovePass);
  assert(passOne.legal);
  auto passTwo = BoardLogic::playMove(passOne.next, rules, kMovePass);
  assert(passTwo.legal);
  afterPasses = std::move(passTwo.next);
  assert(afterPasses.cells == direct.cells);
  assert(afterPasses.nextPla == direct.nextPla);

  SearchParams params;
  MCTSStore directStore = MCTSStore::create(direct, rules, makeKey(1, ModelId::b6, rules), params);
  MCTSStore historyStore = MCTSStore::create(afterPasses, rules, makeKey(2, ModelId::b6, rules), params);
  assert(directStore.snapshot().rootLineageHash != historyStore.snapshot().rootLineageHash);
}

void testSparseMemoryLayout() {
  Rules rules;
  SearchParams params;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, makeKey(3, ModelId::b6, rules), params
  );
  UniformEvaluator evaluator;
  store.setEvaluator(&evaluator);
  store.runPlayouts(256);
  const StoreMemoryStats memory = store.memoryStats();
  assert(memory.nodeCount >= 2);
  assert(memory.actionCount <= 255);
  assert(memory.actionCount + 1 >= memory.nodeCount);
  assert(memory.policyFloatCount % kMoveCount == 0);
  assert(memory.policyFloatCount <= memory.nodeCount * kMoveCount);
  assert(memory.ownershipFloatCount % kOwnershipDim == 0);
  assert(memory.ownershipFloatCount <= memory.nodeCount * kOwnershipDim);
  assert(memory.estimatedArenaBytes < 16ULL * 1024ULL * 1024ULL);
}

std::vector<NodeId> buildVisibleLine(MCTSStore& store, size_t moveCount) {
  static const std::array<Point, 20> points = {{
    {3, 3}, {15, 15}, {15, 3}, {3, 15}, {9, 9},
    {4, 4}, {14, 14}, {14, 4}, {4, 14}, {10, 10},
    {5, 5}, {13, 13}, {13, 5}, {5, 13}, {8, 8},
    {6, 6}, {12, 12}, {12, 6}, {6, 12}, {11, 11},
  }};
  assert(moveCount <= points.size());
  std::vector<NodeId> result{store.currentRoot()};
  for(size_t i = 0; i < moveCount; ++i) {
    PlayMoveCommit commit = store.playMoveFromRoot(pointToMove(points[i].x, points[i].y));
    assert(commit.ok);
    result.push_back(commit.node);
  }
  return result;
}

void assertOutsideSubtreeUnchanged(
  const MCTSStore& store,
  NodeId searchRoot,
  const std::vector<Node>& beforeNodes,
  const std::vector<Action>& beforeActions
) {
  const auto& afterNodes = store.nodeArray();
  assert(afterNodes.size() >= beforeNodes.size());
  for(NodeId id = 0; id < beforeNodes.size(); ++id) {
    if(store.isAncestorOrSelf(searchRoot, id))
      continue;
    assert(afterNodes[id].visits == beforeNodes[id].visits);
    assert(sameStats(afterNodes[id].stats, beforeNodes[id].stats));
    assert(afterNodes[id].ownershipOffset == beforeNodes[id].ownershipOffset);
  }
  const auto& afterActions = store.actionArray();
  assert(afterActions.size() >= beforeActions.size());
  for(ActionId id = 0; id < beforeActions.size(); ++id) {
    if(store.isAncestorOrSelf(searchRoot, beforeActions[id].parent))
      continue;
    assert(afterActions[id].visits == beforeActions[id].visits);
    assert(sameStats(afterActions[id].stats, beforeActions[id].stats));
    assert(afterActions[id].child == beforeActions[id].child);
  }
}

void testArbitraryRootSwitchIsolationAndReload() {
  Rules rules;
  SearchParams params;
  params.seed = 0x105517869ULL;
  params.rootNoise = 0.0f;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, makeKey(4, ModelId::b18nbt, rules), params
  );
  UniformEvaluator evaluator;
  store.setEvaluator(&evaluator);
  const std::vector<NodeId> line = buildVisibleLine(store, 15);

  std::mt19937 random(0x517869U);
  std::uniform_int_distribution<size_t> rootDistribution(0, line.size() - 1);
  const std::set<size_t> reloadAt = {7, 19, 34, 52, 68, 87, 99};
  for(size_t step = 0; step < 105; ++step) {
    const NodeId selectedRoot = line[rootDistribution(random)];
    std::string error;
    assert(store.switchRoot(selectedRoot, &error));
    const std::vector<Node> beforeNodes = store.nodeArray();
    const std::vector<Action> beforeActions = store.actionArray();
    store.runPlayouts(64);
    assertOutsideSubtreeUnchanged(store, selectedRoot, beforeNodes, beforeActions);

    if(reloadAt.count(step) != 0) {
      const RootSnapshot before = store.snapshot();
      const std::vector<uint8_t> bytes = store.serialize();
      auto loaded = MCTSStore::deserialize(bytes, &error);
      assert(loaded.has_value());
      store = std::move(*loaded);
      store.setEvaluator(&evaluator);
      const RootSnapshot after = store.snapshot();
      assert(after.rootLineageHash == before.rootLineageHash);
      assert(after.rootVisits == before.rootVisits);
      assert(after.candidates.size() == before.candidates.size());
    }
  }
  std::string validationError;
  assert(store.validate(&validationError));
}

void testSerializerRejectsDamage() {
  Rules rules;
  SearchParams params;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, makeKey(5, ModelId::b6, rules), params
  );
  UniformEvaluator evaluator;
  store.setEvaluator(&evaluator);
  store.runPlayouts(32);
  std::vector<uint8_t> bytes = store.serialize();
  std::string error;

  std::vector<uint8_t> truncated(bytes.begin(), bytes.end() - 3);
  assert(!MCTSStore::deserialize(truncated, &error));
  bytes[bytes.size() / 2] ^= 0x80U;
  assert(!MCTSStore::deserialize(bytes, &error));
}

} // namespace

int main() {
  testHistorySensitiveLineage();
  testSparseMemoryLayout();
  testArbitraryRootSwitchIsolationAndReload();
  testSerializerRejectsDamage();
  std::cout << "qixi_core_invariants passed\n";
  return 0;
}
