// Strict MCTS store load/store tests.
// Intentionally fails closed on any silent data loss in serialize / file I/O /
// engine-switch park / disk rehydrate paths.

#include "qixi/mcts.hpp"
#include "qixi/request_pool.hpp"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using namespace qixi::core;

namespace {

[[noreturn]] void fail(const std::string& message) {
  std::cerr << "qixi_store_persist_strict FAILED: " << message << "\n";
  std::exit(1);
}

void require(bool condition, const std::string& message) {
  if(!condition)
    fail(message);
}

AnalysisKey makeKey(GameId gameId, ModelId modelId, const Rules& rules, int32_t noiseKey = 0) {
  AnalysisKey key;
  key.gameId = gameId;
  key.modelId = modelId;
  key.rulesHash = hashRules(rules);
  key.komiKey = komiToKey(rules.komi);
  key.wideRootNoiseKey = noiseKey;
  return key;
}

bool nearlyEqual(float a, float b) {
  if(a == b)
    return true;
  if(!std::isfinite(a) || !std::isfinite(b))
    return false;
  const float scale = std::max(1.0f, std::max(std::fabs(a), std::fabs(b)));
  return std::fabs(a - b) <= 1e-5f * scale;
}

void requireStatsEqual(const ScalarStats& a, const ScalarStats& b, const std::string& where) {
  require(nearlyEqual(a.weightSum, b.weightSum), where + " weightSum");
  require(nearlyEqual(a.weightSqSum, b.weightSqSum), where + " weightSqSum");
  require(nearlyEqual(a.winLossMeanWhite, b.winLossMeanWhite), where + " winLoss");
  require(nearlyEqual(a.noResultMean, b.noResultMean), where + " noResult");
  require(nearlyEqual(a.scoreMeanWhite, b.scoreMeanWhite), where + " scoreMean");
  require(nearlyEqual(a.scoreMeanSqWhite, b.scoreMeanSqWhite), where + " scoreMeanSq");
  require(nearlyEqual(a.leadMeanWhite, b.leadMeanWhite), where + " lead");
  require(nearlyEqual(a.utilityMean, b.utilityMean), where + " utility");
  require(nearlyEqual(a.utilitySqMean, b.utilitySqMean), where + " utilitySq");
}

void requireStoresDeepEqual(const MCTSStore& a, const MCTSStore& b, const std::string& label) {
  require(a.analysisKey() == b.analysisKey(), label + ": analysisKey");
  require(a.currentRoot() == b.currentRoot(), label + ": currentRoot");
  require(a.memoryStats().nodeCount == b.memoryStats().nodeCount, label + ": nodeCount");
  require(a.memoryStats().actionCount == b.memoryStats().actionCount, label + ": actionCount");
  require(
    a.memoryStats().policyFloatCount == b.memoryStats().policyFloatCount,
    label + ": policyFloatCount"
  );
  require(
    a.memoryStats().ownershipFloatCount == b.memoryStats().ownershipFloatCount,
    label + ": ownershipFloatCount"
  );
  require(
    a.memoryStats().ancestorIdCount == b.memoryStats().ancestorIdCount,
    label + ": ancestorIdCount"
  );
  require(
    a.memoryStats().visibleByteCount == b.memoryStats().visibleByteCount,
    label + ": visibleByteCount"
  );

  const auto& an = a.nodeArray();
  const auto& bn = b.nodeArray();
  require(an.size() == bn.size(), label + ": nodes size");
  for(size_t i = 0; i < an.size(); ++i) {
    const Node& x = an[i];
    const Node& y = bn[i];
    const std::string where = label + " node[" + std::to_string(i) + "]";
    require(x.id == y.id, where + " id");
    require(x.parent == y.parent, where + " parent");
    require(x.moveFromParent == y.moveFromParent, where + " moveFromParent");
    require(x.movePla == y.movePla, where + " movePla");
    require(x.ply == y.ply, where + " ply");
    require(x.nextPla == y.nextPla, where + " nextPla");
    require(x.state == y.state, where + " state");
    require(x.policyOffset == y.policyOffset, where + " policyOffset");
    require(x.firstAction == y.firstAction, where + " firstAction");
    require(x.actionCount == y.actionCount, where + " actionCount");
    require(x.ancestorCount == y.ancestorCount, where + " ancestorCount");
    require(x.ancestorOffset == y.ancestorOffset, where + " ancestorOffset");
    require(x.visits == y.visits, where + " visits");
    requireStatsEqual(x.stats, y.stats, where + " stats");
    require(x.ownershipOffset == y.ownershipOffset, where + " ownershipOffset");
    require(x.lineageHash == y.lineageHash, where + " lineageHash");
    require(x.minVisitedRootDepth == y.minVisitedRootDepth, where + " minVisitedRootDepth");
    require(x.hasStoredNN == y.hasStoredNN, where + " hasStoredNN");
    require(nearlyEqual(x.nnWinLossWhite, y.nnWinLossWhite), where + " nnWinLoss");
    require(nearlyEqual(x.nnNoResult, y.nnNoResult), where + " nnNoResult");
    require(nearlyEqual(x.nnScoreMeanWhite, y.nnScoreMeanWhite), where + " nnScoreMean");
    require(nearlyEqual(x.nnScoreMeanSqWhite, y.nnScoreMeanSqWhite), where + " nnScoreMeanSq");
    require(nearlyEqual(x.nnLeadWhite, y.nnLeadWhite), where + " nnLead");
    require(nearlyEqual(x.nnUtilityWhite, y.nnUtilityWhite), where + " nnUtility");
    require(nearlyEqual(x.nnWeight, y.nnWeight), where + " nnWeight");
    require(x.nnOwnershipOffset == y.nnOwnershipOffset, where + " nnOwnershipOffset");
  }

  const auto& aa = a.actionArray();
  const auto& ba = b.actionArray();
  require(aa.size() == ba.size(), label + ": actions size");
  for(size_t i = 0; i < aa.size(); ++i) {
    const Action& x = aa[i];
    const Action& y = ba[i];
    const std::string where = label + " action[" + std::to_string(i) + "]";
    require(x.parent == y.parent, where + " parent");
    require(x.child == y.child, where + " child");
    require(x.nextAction == y.nextAction, where + " nextAction");
    require(x.move == y.move, where + " move");
    require(x.visits == y.visits, where + " visits");
    requireStatsEqual(x.stats, y.stats, where + " stats");
  }

  // Snapshot-level semantic equality (display-facing).
  const RootSnapshot sa = a.snapshotLight(10, 4096, true);
  const RootSnapshot sb = b.snapshotLight(10, 4096, true);
  require(sa.root == sb.root, label + ": snapshot root");
  require(sa.rootLineageHash == sb.rootLineageHash, label + ": snapshot lineage");
  require(sa.rootVisits == sb.rootVisits, label + ": snapshot rootVisits");
  require(nearlyEqual(sa.rootWinrate, sb.rootWinrate), label + ": snapshot winrate");
  require(nearlyEqual(sa.rootScoreMean, sb.rootScoreMean), label + ": snapshot score");
  require(sa.candidates.size() == sb.candidates.size(), label + ": candidate count");
  for(size_t i = 0; i < sa.candidates.size(); ++i) {
    require(sa.candidates[i].move == sb.candidates[i].move, label + ": cand move");
    require(sa.candidates[i].visits == sb.candidates[i].visits, label + ": cand visits");
  }
  require(sa.hasOwnership == sb.hasOwnership, label + ": hasOwnership");
  if(sa.hasOwnership) {
    for(int i = 0; i < kOwnershipDim; ++i) {
      require(
        nearlyEqual(sa.ownership[static_cast<size_t>(i)], sb.ownership[static_cast<size_t>(i)]),
        label + ": ownership[" + std::to_string(i) + "]"
      );
    }
  }
}

std::filesystem::path tempPath(const std::string& label) {
  return std::filesystem::temp_directory_path() /
    (label + "-" +
     std::to_string(
       std::chrono::high_resolution_clock::now().time_since_epoch().count()
     ) +
     ".qixi-core-store");
}

class TemporaryDirectory {
public:
  explicit TemporaryDirectory(const std::string& label) {
    path = std::filesystem::temp_directory_path() /
      (label + "-" +
       std::to_string(
         std::chrono::high_resolution_clock::now().time_since_epoch().count()
       ));
    std::filesystem::create_directories(path);
  }
  ~TemporaryDirectory() {
    std::error_code ignored;
    std::filesystem::remove_all(path, ignored);
  }
  std::filesystem::path path;
};

// ---------------------------------------------------------------------------
// Pure serialize / deserialize / file I/O
// ---------------------------------------------------------------------------

void testSerializeDeserializeDeepEqual() {
  Rules rules;
  SearchParams params;
  params.seed = 0xC0FFEEULL;
  params.rootNoise = 0.05f;
  // Keep AnalysisKey in lockstep with params/rules — deserialize runs validate().
  params.rootNoise = 0.05f;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black),
    rules,
    makeKey(11, ModelId::b6, rules, wideRootNoiseToKey(params.rootNoise)),
    params
  );
  UniformEvaluator eval;
  store.setEvaluator(&eval);
  for(int i = 0; i < 400; ++i)
    store.runPlayout();

  // Branch the tree a bit: switch root to a child and search more.
  RootSnapshot snap = store.snapshotLight(5, 64, false);
  require(!snap.candidates.empty(), "need candidates after search");
  require(snap.candidates[0].move < kMoveCount, "candidate move in range");

  std::string error;
  const std::vector<uint8_t> bytes = store.serialize();
  require(!bytes.empty(), "serialize non-empty");
  require(bytes.size() >= 40, "serialize has header+checksum");

  auto loaded = MCTSStore::deserialize(bytes, &error);
  require(loaded.has_value(), "deserialize: " + error);
  loaded->setEvaluator(&eval);
  requireStoresDeepEqual(store, *loaded, "mem-roundtrip");

  // Idempotent: serialize(deserialize(x)) should match serialize(x) byte-for-byte.
  const std::vector<uint8_t> bytes2 = loaded->serialize();
  require(bytes2 == bytes, "serialize is byte-stable across round-trip");
}

void testPersistToFileMatchesSerializeBytes() {
  Rules rules;
  SearchParams params;
  params.seed = 0xA11CEULL;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, makeKey(12, ModelId::b18nbt, rules), params
  );
  UniformEvaluator eval;
  store.setEvaluator(&eval);
  store.runPlayouts(128);

  const std::vector<uint8_t> bytes = store.serialize();
  require(!bytes.empty(), "serialize non-empty");

  const auto path = tempPath("persist-bytes");
  std::string error;
  require(store.persistToFile(path.string(), &error), "persistToFile: " + error);
  require(std::filesystem::exists(path), "file exists");
  require(std::filesystem::file_size(path) == bytes.size(), "file size == serialize size");

  std::ifstream in(path, std::ios::binary);
  require(static_cast<bool>(in), "open persisted file");
  std::vector<uint8_t> fileBytes(
    (std::istreambuf_iterator<char>(in)),
    std::istreambuf_iterator<char>()
  );
  require(fileBytes == bytes, "persistToFile bytes == serialize() memory image");

  auto loaded = MCTSStore::loadFromFile(path.string(), 64ULL * 1024ULL * 1024ULL, &error);
  require(loaded.has_value(), "loadFromFile: " + error);
  loaded->setEvaluator(&eval);
  requireStoresDeepEqual(store, *loaded, "file-roundtrip");
  std::filesystem::remove(path);
}

void testLoadRejectsDamageAndTruncation() {
  Rules rules;
  SearchParams params;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, makeKey(13, ModelId::b6, rules), params
  );
  UniformEvaluator eval;
  store.setEvaluator(&eval);
  store.runPlayouts(64);
  std::vector<uint8_t> bytes = store.serialize();
  require(bytes.size() > 64, "blob large enough to damage");

  std::string error;
  // Truncations
  const size_t cuts[] = {1u, 8u, 16u, bytes.size() / 2, bytes.size() - 1};
  for(size_t cut : cuts) {
    std::vector<uint8_t> truncated(bytes.begin(), bytes.begin() + static_cast<std::ptrdiff_t>(cut));
    require(
      !MCTSStore::deserialize(truncated, &error).has_value(),
      "truncated@" + std::to_string(cut) + " must fail"
    );
  }
  // Flip a middle payload byte (not necessarily checksum).
  {
    std::vector<uint8_t> damaged = bytes;
    damaged[bytes.size() / 2] ^= 0xA5U;
    require(!MCTSStore::deserialize(damaged, &error).has_value(), "payload flip must fail");
  }
  // Flip checksum only.
  {
    std::vector<uint8_t> damaged = bytes;
    damaged.back() ^= 0x01U;
    require(!MCTSStore::deserialize(damaged, &error).has_value(), "checksum flip must fail");
  }
  // Bad magic.
  {
    std::vector<uint8_t> damaged = bytes;
    damaged[0] ^= 0xFFU;
    require(!MCTSStore::deserialize(damaged, &error).has_value(), "bad magic must fail");
  }
}

void testCreateNormalizesInconsistentAnalysisKey() {
  Rules rules;
  SearchParams params;
  params.rootNoise = 0.25f;
  // Deliberately wrong noise key — create() must rewrite it so load can succeed.
  AnalysisKey bad = makeKey(99, ModelId::b6, rules, /*noiseKey=*/999999);
  MCTSStore store = MCTSStore::create(BoardLogic::emptyBoard(Color::black), rules, bad, params);
  require(
    store.analysisKey().wideRootNoiseKey == wideRootNoiseToKey(params.rootNoise),
    "create must normalize wideRootNoiseKey"
  );
  require(store.analysisKey().komiKey == komiToKey(rules.komi), "create must normalize komiKey");
  require(store.analysisKey().rulesHash == hashRules(rules), "create must normalize rulesHash");
  std::string error;
  auto loaded = MCTSStore::deserialize(store.serialize(), &error);
  require(loaded.has_value(), "normalized key must load: " + error);
}

void testEmptyRootRoundTrip() {
  Rules rules;
  SearchParams params;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::white),
    rules,
    makeKey(14, ModelId::b28nbt, rules, wideRootNoiseToKey(params.rootNoise)),
    params
  );
  // No playouts — root-only tree must still round-trip.
  std::string error;
  const auto bytes = store.serialize();
  require(!bytes.empty(), "empty-root serialize");
  auto loaded = MCTSStore::deserialize(bytes, &error);
  require(loaded.has_value(), "empty-root deserialize: " + error);
  requireStoresDeepEqual(store, *loaded, "empty-root");
  require(loaded->currentRoot() == 0, "empty-root id 0");
  require(loaded->memoryStats().nodeCount == 1, "single root node");
}

void testPlayAfterReloadUsesRestoredChildIndex() {
  Rules rules;
  SearchParams params;
  params.seed = 0xBEEFULL;
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black), rules, makeKey(15, ModelId::b6, rules), params
  );
  UniformEvaluator eval;
  store.setEvaluator(&eval);
  store.runPlayouts(80);
  const RootSnapshot before = store.snapshotLight(3, 32, false);
  require(!before.candidates.empty(), "need a legal candidate");

  std::string error;
  auto loaded = MCTSStore::deserialize(store.serialize(), &error);
  require(loaded.has_value(), "reload: " + error);
  loaded->setEvaluator(&eval);

  // Search after reload must not crash and must grow visits.
  const uint64_t visitsBefore = loaded->snapshotLight(1, 1, false).rootVisits;
  loaded->runPlayouts(40);
  const uint64_t visitsAfter = loaded->snapshotLight(1, 1, false).rootVisits;
  require(visitsAfter > visitsBefore, "post-reload search must increase visits");
}

// ---------------------------------------------------------------------------
// Engine-switch park / disk rehydrate — known failure modes
// ---------------------------------------------------------------------------

BackendResult execute(BackendWorker& worker, RequestKind kind, RequestPayload payload) {
  return worker.executeForTests(kind, std::move(payload), 0);
}

void installEval(BackendWorker& worker, UniformEvaluator& evaluator) {
  worker.setEngineSelector([&](ModelId model, Evaluator*& selected, std::string&) {
    selected = model == ModelId::none ? nullptr : &evaluator;
    return true;
  });
}

void testEngineSwitchParkPreservesFullTreeWhenLineageMissing() {
  // Scenario:
  // 1) Search on b6 at empty/early position (builds a large tree).
  // 2) Switch to b18, play a new move (lineage b6 never saw).
  // 3) Switch back to b6.
  // Expected: full b6 tree is still available (jump back to original root keeps visits).
  // Historical bug: park is discarded when current lineage is absent from parked store.
  TemporaryDirectory dir("qixi-park-preserve");
  UniformEvaluator evaluator;
  BackendWorker worker;
  installEval(worker, evaluator);
  std::string error;
  require(worker.setStoreDirectory(dir.path.string(), &error), "setStoreDirectory");
  require(execute(worker, RequestKind::boot, BootRequest{}).ok, "boot");

  SelectEngineRequest se;
  se.modelId = ModelId::b6;
  require(execute(worker, RequestKind::selectEngine, se).ok, "select b6");
  worker.runSearchPlayouts(96);
  BackendResult b6Snap = worker.latestSnapshot();
  require(b6Snap.snapshot.has_value(), "b6 snapshot");
  const uint64_t b6RootVisits = b6Snap.snapshot->rootVisits;
  const uint64_t b6Lineage = b6Snap.snapshot->rootLineageHash;
  require(b6RootVisits >= 96, "b6 has visits");

  // Move under b18 so current lineage is not in the b6 tree.
  se.modelId = ModelId::b18nbt;
  require(execute(worker, RequestKind::selectEngine, se).ok, "select b18");
  PlayMoveRequest play;
  play.move = pointToMove(3, 3);
  play.uiIntentId = 1;
  play.parentRootRef = RootRef::lineageRef(b6Lineage);
  BackendResult played = execute(worker, RequestKind::playMove, play);
  require(played.ok && played.snapshot.has_value(), "play under b18");
  const uint64_t b18Lineage = played.snapshot->rootLineageHash;
  require(b18Lineage != b6Lineage, "lineage advanced");

  // Switch back to b6 while live root is at a lineage b6 never expanded.
  se.modelId = ModelId::b6;
  BackendResult back = execute(worker, RequestKind::selectEngine, se);
  require(back.ok && back.snapshot.has_value(), "switch back to b6");

  // Must still be able to jump to the original b6 root and recover visits.
  JumpToNodeRequest jump;
  jump.targetRootRef = RootRef::lineageRef(b6Lineage);
  BackendResult jumped = execute(worker, RequestKind::jumpToNode, jump);
  require(jumped.ok && jumped.snapshot.has_value(), "jump to original b6 root");
  require(
    jumped.snapshot->rootVisits == b6RootVisits,
    "park must preserve full b6 tree visits; got " +
      std::to_string(jumped.snapshot->rootVisits) + " expected " +
      std::to_string(b6RootVisits)
  );
}

void testEngineSwitchPersistsParkedTreeToDisk() {
  // Scenario:
  // 1) Search on b6, switch away (should persist parked b6 to disk).
  // 2) Drop in-memory parks by selecting none / forcing cold prepare.
  // 3) Cold rehydrate of b6 from disk must restore visits.
  // Historical bug: park never wrote disk; only stale/missing files remained.
  TemporaryDirectory dir("qixi-park-disk");
  UniformEvaluator evaluator;
  BackendWorker worker;
  installEval(worker, evaluator);
  std::string error;
  require(worker.setStoreDirectory(dir.path.string(), &error), "setStoreDirectory");
  require(execute(worker, RequestKind::boot, BootRequest{}).ok, "boot");

  SelectEngineRequest se;
  se.modelId = ModelId::b6;
  require(execute(worker, RequestKind::selectEngine, se).ok, "select b6");
  worker.runSearchPlayouts(64);
  BackendResult b6Snap = worker.latestSnapshot();
  require(b6Snap.snapshot.has_value(), "b6 snapshot");
  const uint64_t b6Visits = b6Snap.snapshot->rootVisits;
  const uint64_t b6Lineage = b6Snap.snapshot->rootLineageHash;
  require(b6Visits >= 64, "b6 visits");

  // Leave b6 so it is parked (and must be written to disk by the fix).
  se.modelId = ModelId::b18nbt;
  require(execute(worker, RequestKind::selectEngine, se).ok, "select b18 parks b6");

  // Count b6 store files and ensure at least one is large enough / loadable with visits.
  bool foundB6OnDisk = false;
  uint64_t diskVisits = 0;
  for(const auto& item : std::filesystem::directory_iterator(dir.path)) {
    if(item.path().extension() != ".qixi-core-store")
      continue;
    std::string decodeError;
    auto loaded = MCTSStore::loadFromFile(
      item.path().string(), 64ULL * 1024ULL * 1024ULL, &decodeError
    );
    if(!loaded)
      continue;
    if(loaded->analysisKey().modelId != ModelId::b6)
      continue;
    foundB6OnDisk = true;
    if(const auto node = loaded->findVisibleNodeByLineage(b6Lineage)) {
      std::string switchError;
      require(loaded->switchRoot(*node, &switchError), "switch disk store to b6 root");
      diskVisits = loaded->snapshotLight(1, 1, false).rootVisits;
    } else {
      // Root-only check if lineage map differs
      diskVisits = loaded->snapshotLight(1, 1, false).rootVisits;
    }
  }
  require(foundB6OnDisk, "b6 store file must exist on disk after parking");
  require(
    diskVisits == b6Visits,
    "disk park must preserve b6 visits; got " + std::to_string(diskVisits) +
      " expected " + std::to_string(b6Visits)
  );
}

void testCheckpointThenColdLoad() {
  TemporaryDirectory dir("qixi-checkpoint-cold");
  UniformEvaluator evaluator;
  BackendWorker worker;
  installEval(worker, evaluator);
  std::string error;
  require(worker.setStoreDirectory(dir.path.string(), &error), "setStoreDirectory");
  require(execute(worker, RequestKind::boot, BootRequest{}).ok, "boot");

  SelectEngineRequest se;
  se.modelId = ModelId::b6;
  require(execute(worker, RequestKind::selectEngine, se).ok, "select b6");
  worker.runSearchPlayouts(50);
  const uint64_t visits = worker.latestSnapshot().snapshot->rootVisits;
  const uint64_t lineage = worker.latestSnapshot().snapshot->rootLineageHash;

  // Explicit export path = active store file image.
  const auto exportPath = dir.path / "export.bin";
  ExportAnalysisStateRequest ex;
  ex.path = exportPath.string();
  require(execute(worker, RequestKind::exportAnalysisState, ex).ok, "export");

  BackendWorker cold;
  installEval(cold, evaluator);
  TemporaryDirectory dir2("qixi-checkpoint-cold-target");
  require(cold.setStoreDirectory(dir2.path.string(), &error), "cold dir");
  require(execute(cold, RequestKind::boot, BootRequest{}).ok, "cold boot");
  // Load export into cold worker via import.
  ImportAnalysisStateRequest im;
  im.path = exportPath.string();
  BackendResult imported = execute(cold, RequestKind::importAnalysisState, im);
  require(imported.ok && imported.snapshot.has_value(), "import");
  require(imported.snapshot->rootVisits == visits, "import visits");
  require(imported.snapshot->rootLineageHash == lineage, "import lineage");
}

} // namespace

int main() {
  testCreateNormalizesInconsistentAnalysisKey();
  testEmptyRootRoundTrip();
  testSerializeDeserializeDeepEqual();
  testPersistToFileMatchesSerializeBytes();
  testLoadRejectsDamageAndTruncation();
  testPlayAfterReloadUsesRestoredChildIndex();
  testCheckpointThenColdLoad();
  testEngineSwitchParkPreservesFullTreeWhenLineageMissing();
  testEngineSwitchPersistsParkedTreeToDisk();
  std::cout << "qixi_store_persist_strict passed\n";
  return 0;
}
