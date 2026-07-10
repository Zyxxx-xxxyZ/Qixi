#include "qixi/request_pool.hpp"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <iostream>
#include <limits>
#include <mutex>

using namespace qixi::core;

namespace {

AnalysisKey makeKey(GameId gameId, ModelId modelId, const Rules& rules, int32_t noiseKey) {
  AnalysisKey key;
  key.gameId = gameId;
  key.modelId = modelId;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  key.wideRootNoiseKey = noiseKey;
  return key;
}

const Action* findAction(const MCTSStore& store, NodeId parent, Move move) {
  for(const Action& action : store.actionArray()) {
    if(action.parent == parent && action.move == move)
      return &action;
  }
  return nullptr;
}

class InvalidEvaluator final : public Evaluator {
public:
  bool evaluate(const BoardState&, const Rules&, bool, LeafPayload& output) override {
    output = LeafPayload{};
    output.winLossWhite = std::numeric_limits<float>::quiet_NaN();
    output.weight = 1.0f;
    return true;
  }
};

void testBoardLegality() {
  Rules rules;
  BoardState board = BoardLogic::emptyBoard(Color::black);
  assert(BoardLogic::isLegalMove(board, rules, pointToMove(3, 3)));
  auto first = BoardLogic::playMove(board, rules, pointToMove(3, 3));
  assert(first.legal);
  assert(!BoardLogic::isLegalMove(first.next, rules, pointToMove(3, 3)));
}

void testInPlaceMoveMatchesCopyingAPI() {
  Rules rules;
  BoardState board = BoardLogic::emptyBoard(Color::black);
  const std::array<Move, 4> sequence = {{
    pointToMove(1, 0),
    pointToMove(0, 0),
    pointToMove(0, 1),
    kMovePass,
  }};
  for(Move move : sequence) {
    const LegalResult copied = BoardLogic::playMove(board, rules, move);
    BoardState inPlace = board;
    const InPlaceMoveResult applied = BoardLogic::playMoveInPlace(inPlace, rules, move);
    assert(copied.legal && applied.legal);
    assert(applied.captured == copied.captured);
    assert(inPlace.cells == copied.next.cells);
    assert(inPlace.nextPla == copied.next.nextPla);
    assert(inPlace.simpleKoPoint == copied.next.simpleKoPoint);
    assert(inPlace.boardHashHistory == copied.next.boardHashHistory);
    assert(inPlace.situationHashHistory == copied.next.situationHashHistory);
    assert(inPlace.moves.size() == copied.next.moves.size());
    board = copied.next;
  }

  const BoardState beforeIllegal = board;
  const InPlaceMoveResult illegal = BoardLogic::playMoveInPlace(
    board, rules, pointToMove(1, 0)
  );
  assert(!illegal.legal);
  assert(board.cells == beforeIllegal.cells);
  assert(board.nextPla == beforeIllegal.nextPla);
  assert(board.boardHashHistory == beforeIllegal.boardHashHistory);
  assert(board.moves.size() == beforeIllegal.moves.size());
}

void testTerminalJigoAndInvalidEvaluatorRejection() {
  Rules rules;
  rules.komi = 0.0f;
  AnalysisKey key = makeKey(91, ModelId::b6, rules, 0);
  SearchParams params;
  MCTSStore terminal = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, key, params
  );
  UniformEvaluator uniform;
  terminal.setEvaluator(&uniform);
  assert(terminal.playMoveFromRoot(kMovePass).ok);
  assert(terminal.playMoveFromRoot(kMovePass).ok);
  assert(terminal.runPlayout());
  const RootSnapshot terminalSnapshot = terminal.snapshot();
  assert(terminalSnapshot.rootVisits == 1);
  assert(terminalSnapshot.rootWinrate == 0.5f);

  MCTSStore invalid = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, makeKey(92, ModelId::b6, rules, 0), params
  );
  InvalidEvaluator invalidEvaluator;
  invalid.setEvaluator(&invalidEvaluator);
  assert(!invalid.runPlayout());
  assert(invalid.nodeArray().front().visits == 0);
  assert(invalid.nodeArray().front().state == NodeState::unexpanded);
  assert(invalid.memoryStats().ownershipFloatCount == 0);
}

void testInvalidSettingsAreRejectedBeforeStoreMutation() {
  BackendWorker worker;
  assert(worker.executeForTests(RequestKind::boot, BootRequest{}, 0).ok);
  SetKomiRequest badKomi;
  badKomi.komi = std::numeric_limits<float>::infinity();
  assert(!worker.executeForTests(RequestKind::setKomi, badKomi, 0).ok);
  badKomi.komi = 151.0f;
  assert(!worker.executeForTests(RequestKind::setKomi, badKomi, 0).ok);
  SetWideRootNoiseRequest badNoise;
  badNoise.noise = std::numeric_limits<float>::quiet_NaN();
  assert(!worker.executeForTests(RequestKind::setWideRootNoise, badNoise, 0).ok);
  assert(worker.latestSnapshot().ok);
}

void testRawPlatformAdapterRequestsFailWithoutMutation() {
  BackendWorker worker;
  const BackendResult boot = worker.executeForTests(RequestKind::boot, BootRequest{}, 0);
  assert(boot.ok && boot.snapshot.has_value());
  const RootSnapshot before = *boot.snapshot;

  ImportSGFRequest importSGF;
  importSGF.sgfPath = "/tmp/qixi-raw-import.sgf";
  assert(!worker.executeForTests(RequestKind::importSGF, importSGF, 0).ok);

  ExportSGFRequest exportSGF;
  exportSGF.path = "/tmp/qixi-raw-export.sgf";
  assert(!worker.executeForTests(RequestKind::exportSGF, exportSGF, 0).ok);

  RecognizePhotoRequest recognizePhoto;
  recognizePhoto.imagePath = "/tmp/qixi-raw-photo.png";
  assert(!worker.executeForTests(RequestKind::recognizePhoto, recognizePhoto, 0).ok);

  const BackendResult after = worker.latestSnapshot();
  assert(after.ok && after.snapshot.has_value());
  assert(after.snapshot->root == before.root);
  assert(after.snapshot->rootLineageHash == before.rootLineageHash);
  assert(after.snapshot->rootVisits == before.rootVisits);
}

void testPersistentMCTSNoAncestorPollution() {
  Rules rules;
  AnalysisKey key = makeKey(1, ModelId::b6, rules, 0);
  SearchParams params;
  BoardState board = BoardLogic::emptyBoard(Color::black);
  MCTSStore store = MCTSStore::create(board, rules, key, params);
  UniformEvaluator evaluator;
  store.setEvaluator(&evaluator);

  store.runPlayouts(32);
  const RootSnapshot parentSnapshot = store.snapshot();
  Move move = kMovePass;
  for(const Action& action : store.actionArray()) {
    if(action.parent == 0) {
      move = action.move;
      break;
    }
  }
  const Action* actionBefore = findAction(store, 0, move);
  assert(actionBefore != nullptr);
  const uint64_t visitsBefore = actionBefore->visits;
  float selectedWinrate = 0.0f;
  float bestWinrate = 0.0f;
  bool foundSelected = false;
  bool foundBest = false;
  for(const CandidateSnapshot& candidate : parentSnapshot.candidates) {
    if(candidate.visits == 0)
      continue;
    if(!foundBest || candidate.winrate > bestWinrate)
      bestWinrate = candidate.winrate;
    foundBest = true;
    if(candidate.move == move) {
      selectedWinrate = candidate.winrate;
      foundSelected = true;
    }
  }
  assert(foundSelected && foundBest);
  const float expectedQualityDelta = (selectedWinrate - bestWinrate) * 100.0f;

  PlayMoveCommit commit = store.playMoveFromRoot(move);
  assert(commit.ok);
  const NodeId child = commit.node;
  const RootSnapshot beforeChildSearch = store.snapshot();
  const auto childBefore = std::find_if(
    beforeChildSearch.visibleTree.begin(), beforeChildSearch.visibleTree.end(),
    [&](const TreeNodeSnapshot& item) { return item.id == child; }
  );
  assert(childBefore != beforeChildSearch.visibleTree.end());
  assert(childBefore->hasQualityDelta);
  assert(std::fabs(childBefore->qualityDeltaPercent - expectedQualityDelta) < 1.0e-5f);
  store.runPlayouts(64);
  const RootSnapshot afterChildSearch = store.snapshot();
  const auto childAfter = std::find_if(
    afterChildSearch.visibleTree.begin(), afterChildSearch.visibleTree.end(),
    [&](const TreeNodeSnapshot& item) { return item.id == child; }
  );
  assert(childAfter != afterChildSearch.visibleTree.end());
  assert(childAfter->hasQualityDelta);
  assert(std::fabs(childAfter->qualityDeltaPercent - expectedQualityDelta) < 1.0e-5f);
  assert(store.switchRoot(0, nullptr));

  const Action* actionAfter = findAction(store, 0, move);
  assert(actionAfter != nullptr);
  assert(actionAfter->visits == visitsBefore);
  assert(store.switchRoot(child, nullptr));
  assert(store.nodeArray()[child].visits > 0);
}

void testRoundTrip() {
  Rules rules;
  AnalysisKey key = makeKey(2, ModelId::b6, rules, 0);
  SearchParams params;
  MCTSStore store = MCTSStore::create(BoardLogic::emptyBoard(Color::black), rules, key, params);
  UniformEvaluator evaluator;
  store.setEvaluator(&evaluator);
  store.runPlayouts(16);
  auto bytes = store.serialize();
  std::string error;
  auto loaded = MCTSStore::deserialize(bytes, &error);
  assert(loaded.has_value());
  assert(loaded->nodeArray().size() == store.nodeArray().size());
  assert(loaded->actionArray().size() == store.actionArray().size());
  assert(loaded->currentRoot() == store.currentRoot());
}

void testRequestWorkerFIFO() {
  UniformEvaluator evaluator;
  BackendWorker worker;
  worker.setEvaluator(&evaluator);

  auto boot = worker.executeForTests(RequestKind::boot, BootRequest{}, 0);
  assert(boot.ok);
  const BackendEpoch epoch = boot.backendEpoch;

  PlayMoveRequest first;
  first.move = pointToMove(3, 3);
  first.uiIntentId = 100;
  first.parentRootRef = RootRef::nodeRef(0);
  auto r1 = worker.executeForTests(RequestKind::playMove, first, epoch);
  assert(r1.ok);

  PlayMoveRequest second;
  second.move = pointToMove(15, 15);
  second.uiIntentId = 101;
  second.parentRootRef = RootRef::intentRef(100);
  auto r2 = worker.executeForTests(RequestKind::playMove, second, epoch);
  assert(r2.ok);
}

void testLiveWorkerFIFOAndIntentChaining() {
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<BackendResult> results;
  BackendWorker worker([&](const BackendResult& result) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      results.push_back(result);
    }
    condition.notify_all();
  });
  UniformEvaluator evaluator;
  worker.setEngineSelector([&](ModelId model, Evaluator*& selected, std::string&) {
    selected = model == ModelId::none ? nullptr : &evaluator;
    return true;
  });

  BackendResult boot = worker.submitAndWait(RequestKind::boot, BootRequest{}, 0);
  assert(boot.ok);
  {
    std::lock_guard<std::mutex> lock(mutex);
    results.clear();
  }

  SelectEngineRequest select;
  select.modelId = ModelId::b6;
  const RequestId selectId = worker.submit(RequestKind::selectEngine, select, 0);

  PlayMoveRequest first;
  first.move = pointToMove(3, 3);
  first.uiIntentId = 300;
  first.parentRootRef = RootRef::nodeRef(0);
  const RequestId firstId = worker.submit(RequestKind::playMove, first, 0);

  PlayMoveRequest second;
  second.move = pointToMove(15, 15);
  second.uiIntentId = 301;
  second.parentRootRef = RootRef::intentRef(300);
  const RequestId secondId = worker.submit(RequestKind::playMove, second, 0);

  {
    std::unique_lock<std::mutex> lock(mutex);
    const bool completed = condition.wait_for(lock, std::chrono::seconds(5), [&]() {
      return results.size() >= 3;
    });
    assert(completed);
    assert(results[0].requestId == selectId && results[0].ok);
    assert(results[1].requestId == firstId && results[1].ok);
    assert(results[2].requestId == secondId && results[2].ok);
    assert(results[2].snapshot.has_value());
    assert(results[2].snapshot->visibleTree.size() == 3);
    assert(results[2].snapshot->root == results[2].currentRoot);
  }
  worker.stop();
}

void testFailedEngineSelectionRetainsRestoredEvaluator() {
  BackendWorker worker;
  UniformEvaluator evaluator;
  worker.setEngineSelector([&](ModelId model, Evaluator*& selected, std::string& error) {
    if(model == ModelId::b18nbt) {
      selected = &evaluator;
      error = "target load failed; previous model restored";
      return false;
    }
    selected = model == ModelId::none ? nullptr : &evaluator;
    return true;
  });

  assert(worker.executeForTests(RequestKind::boot, BootRequest{}, 0).ok);
  SelectEngineRequest selectB6;
  selectB6.modelId = ModelId::b6;
  assert(worker.executeForTests(RequestKind::selectEngine, selectB6, 0).ok);
  worker.runSearchPlayouts(1);
  const BackendResult beforeFailure = worker.latestSnapshot();
  assert(beforeFailure.snapshot.has_value());

  SelectEngineRequest selectB18;
  selectB18.modelId = ModelId::b18nbt;
  const BackendResult failed = worker.executeForTests(RequestKind::selectEngine, selectB18, 0);
  assert(!failed.ok);
  assert(failed.engineState == EngineState::ready);
  worker.runSearchPlayouts(1);
  const BackendResult afterFailure = worker.latestSnapshot();
  assert(afterFailure.ok);
  assert(afterFailure.snapshot.has_value());
  assert(afterFailure.snapshot->rootVisits > beforeFailure.snapshot->rootVisits);
}

void testNoEngineRoundTripRetainsLiveStoreWithoutDisk() {
  BackendWorker worker;
  UniformEvaluator evaluator;
  worker.setEngineSelector([&](ModelId model, Evaluator*& selected, std::string&) {
    selected = model == ModelId::none ? nullptr : &evaluator;
    return true;
  });
  assert(worker.executeForTests(RequestKind::boot, BootRequest{}, 0).ok);
  SelectEngineRequest select;
  select.modelId = ModelId::b6;
  assert(worker.executeForTests(RequestKind::selectEngine, select, 0).ok);
  worker.runSearchPlayouts(8);
  const BackendResult beforeUnload = worker.latestSnapshot();
  assert(beforeUnload.snapshot.has_value());
  assert(beforeUnload.snapshot->rootVisits == 8);

  select.modelId = ModelId::none;
  assert(worker.executeForTests(RequestKind::selectEngine, select, 0).ok);
  select.modelId = ModelId::b6;
  assert(worker.executeForTests(RequestKind::selectEngine, select, 0).ok);
  const BackendResult afterReload = worker.latestSnapshot();
  assert(afterReload.snapshot.has_value());
  assert(afterReload.snapshot->rootVisits == beforeUnload.snapshot->rootVisits);
}

} // namespace

int main() {
  testBoardLegality();
  testInPlaceMoveMatchesCopyingAPI();
  testTerminalJigoAndInvalidEvaluatorRejection();
  testInvalidSettingsAreRejectedBeforeStoreMutation();
  testRawPlatformAdapterRequestsFailWithoutMutation();
  testPersistentMCTSNoAncestorPollution();
  testRoundTrip();
  testRequestWorkerFIFO();
  testLiveWorkerFIFOAndIntentChaining();
  testFailedEngineSelectionRetainsRestoredEvaluator();
  testNoEngineRoundTripRetainsLiveStoreWithoutDisk();
  std::cout << "qixi_core_smoke passed\n";
  return 0;
}
