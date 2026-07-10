#include "qixi/request_pool.hpp"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

using namespace qixi::core;

namespace {

class TemporaryDirectory {
public:
  explicit TemporaryDirectory(const std::string& label) {
    path = std::filesystem::temp_directory_path() /
      (label + "-" + std::to_string(
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

BackendResult execute(BackendWorker& worker, RequestKind kind, RequestPayload payload) {
  return worker.executeForTests(kind, std::move(payload), 0);
}

std::vector<uint8_t> readBytes(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  assert(input);
  return std::vector<uint8_t>(
    std::istreambuf_iterator<char>(input),
    std::istreambuf_iterator<char>()
  );
}

void installEvaluatorSelector(BackendWorker& worker, UniformEvaluator& evaluator) {
  worker.setEngineSelector([&](ModelId model, Evaluator*& selected, std::string&) {
    selected = model == ModelId::none ? nullptr : &evaluator;
    return true;
  });
}

BackendResult selectEngine(BackendWorker& worker, ModelId model) {
  SelectEngineRequest request;
  request.modelId = model;
  return execute(worker, RequestKind::selectEngine, request);
}

BackendResult play(
  BackendWorker& worker,
  Move move,
  UiIntentId intent,
  RootRef parent
) {
  PlayMoveRequest request;
  request.move = move;
  request.uiIntentId = intent;
  request.parentRootRef = parent;
  return execute(worker, RequestKind::playMove, request);
}

void testModelStoreMergeAndBundleRoundTrip() {
  TemporaryDirectory sourceDirectory("qixi-core-source");
  TemporaryDirectory targetDirectory("qixi-core-target");
  const std::filesystem::path bundlePath = sourceDirectory.path / "all-settings.qixi-core-bundle";
  const std::filesystem::path corruptPath = sourceDirectory.path / "corrupt.qixi-core-bundle";
  UniformEvaluator evaluator;

  BackendWorker source;
  installEvaluatorSelector(source, evaluator);
  std::string error;
  assert(source.setStoreDirectory(sourceDirectory.path.string(), &error));
  assert(execute(source, RequestKind::boot, BootRequest{}).ok);
  assert(selectEngine(source, ModelId::b6).ok);

  BackendResult firstMove = play(source, pointToMove(3, 3), 100, RootRef::nodeRef(0));
  assert(firstMove.ok && firstMove.snapshot.has_value());
  const uint64_t firstLineage = firstMove.snapshot->rootLineageHash;
  source.runSearchPlayouts(48);
  BackendResult b6Analyzed = source.latestSnapshot();
  assert(b6Analyzed.snapshot->rootVisits >= 48);
  const uint64_t b6Visits = b6Analyzed.snapshot->rootVisits;

  assert(selectEngine(source, ModelId::b18nbt).ok);
  BackendResult b18Initial = source.latestSnapshot();
  assert(b18Initial.snapshot->rootLineageHash == firstLineage);
  assert(b18Initial.snapshot->rootVisits == 0);
  BackendResult secondMove = play(
    source,
    pointToMove(15, 15),
    101,
    RootRef::lineageRef(firstLineage)
  );
  assert(secondMove.ok && secondMove.snapshot.has_value());
  const uint64_t secondLineage = secondMove.snapshot->rootLineageHash;
  source.runSearchPlayouts(24);
  const uint64_t b18Visits = source.latestSnapshot().snapshot->rootVisits;
  assert(b18Visits >= 24);

  BackendResult backToB6 = selectEngine(source, ModelId::b6);
  assert(backToB6.ok && backToB6.snapshot.has_value());
  assert(backToB6.snapshot->rootLineageHash == secondLineage);
  assert(backToB6.snapshot->rootVisits == 0);
  JumpToNodeRequest jumpFirst;
  jumpFirst.targetRootRef = RootRef::lineageRef(firstLineage);
  BackendResult firstOnB6 = execute(source, RequestKind::jumpToNode, jumpFirst);
  assert(firstOnB6.ok && firstOnB6.snapshot->rootVisits == b6Visits);

  BackendResult noEngine = selectEngine(source, ModelId::none);
  assert(noEngine.ok && noEngine.snapshot.has_value());
  assert(noEngine.snapshot->rootVisits == b6Visits);
  assert(noEngine.snapshot->rootLineageHash == firstLineage);

  assert(selectEngine(source, ModelId::b18nbt).ok);
  JumpToNodeRequest jumpSecond;
  jumpSecond.targetRootRef = RootRef::lineageRef(secondLineage);
  BackendResult secondOnB18 = execute(source, RequestKind::jumpToNode, jumpSecond);
  assert(secondOnB18.ok && secondOnB18.snapshot->rootVisits == b18Visits);

  ExportAnalysisStateRequest exportRequest;
  exportRequest.path = bundlePath.string();
  assert(execute(source, RequestKind::exportAnalysisState, exportRequest).ok);
  assert(std::filesystem::file_size(bundlePath) > 0);

  std::filesystem::copy_file(bundlePath, corruptPath);
  {
    std::fstream file(corruptPath, std::ios::in | std::ios::out | std::ios::binary);
    assert(file);
    file.seekg(32);
    char byte = 0;
    file.read(&byte, 1);
    byte ^= 0x40;
    file.seekp(32);
    file.write(&byte, 1);
  }

  BackendWorker target;
  installEvaluatorSelector(target, evaluator);
  assert(target.setStoreDirectory(targetDirectory.path.string(), &error));
  assert(execute(target, RequestKind::boot, BootRequest{}).ok);
  ImportAnalysisStateRequest importRequest;
  importRequest.path = bundlePath.string();
  BackendResult imported = execute(target, RequestKind::importAnalysisState, importRequest);
  assert(imported.ok && imported.snapshot.has_value());
  assert(imported.snapshot->rootLineageHash == secondLineage);
  assert(imported.snapshot->rootVisits == b18Visits);

  std::vector<std::string> importedFilenames;
  for(const auto& item : std::filesystem::directory_iterator(targetDirectory.path)) {
    if(item.path().extension() != ".qixi-core-store")
      continue;
    std::string decodeError;
    auto decoded = MCTSStore::deserialize(readBytes(item.path()), &decodeError);
    assert(decoded.has_value());
    if(decoded->analysisKey().gameId == 2)
      importedFilenames.push_back(item.path().filename().string());
  }
  std::sort(importedFilenames.begin(), importedFilenames.end());
  assert(importedFilenames.size() >= 2);

  TemporaryDirectory collisionDirectory("qixi-core-collision");
  BackendWorker collisionTarget;
  installEvaluatorSelector(collisionTarget, evaluator);
  assert(collisionTarget.setStoreDirectory(collisionDirectory.path.string(), &error));
  assert(execute(collisionTarget, RequestKind::boot, BootRequest{}).ok);
  const std::string collisionFilename = importedFilenames.back();
  {
    std::ofstream collision(collisionDirectory.path / collisionFilename, std::ios::binary);
    assert(collision);
    collision << "preexisting-store";
  }
  importRequest.path = bundlePath.string();
  BackendResult collision = execute(
    collisionTarget, RequestKind::importAnalysisState, importRequest
  );
  assert(!collision.ok);
  assert(!std::filesystem::exists(collisionDirectory.path / "active-store.index"));
  for(const std::string& filename : importedFilenames) {
    const bool shouldExist = filename == collisionFilename;
    assert(std::filesystem::exists(collisionDirectory.path / filename) == shouldExist);
  }

  assert(selectEngine(target, ModelId::b6).ok);
  BackendResult importedB6 = execute(target, RequestKind::jumpToNode, jumpFirst);
  assert(importedB6.ok && importedB6.snapshot->rootVisits == b6Visits);

  const uint64_t beforeCorruptImport = importedB6.snapshot->rootVisits;
  importRequest.path = corruptPath.string();
  BackendResult corrupt = execute(target, RequestKind::importAnalysisState, importRequest);
  assert(!corrupt.ok);
  assert(target.latestSnapshot().snapshot->rootVisits == beforeCorruptImport);
}

} // namespace

int main() {
  testModelStoreMergeAndBundleRoundTrip();
  std::cout << "qixi_core_store_bundle passed\n";
  return 0;
}
