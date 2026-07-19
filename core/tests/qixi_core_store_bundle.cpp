#include "qixi/request_pool.hpp"

#include <cassert>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

using namespace qixi::core;

namespace {

void require(bool condition, const char* message) {
  if(!condition) {
    std::cerr << "qixi_core_store_bundle failed: " << message << "\n";
    std::exit(1);
  }
}

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
  require(static_cast<bool>(input), "could not open file for reading");
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

void testActiveStoreExportImportRoundTrip() {
  TemporaryDirectory sourceDirectory("qixi-core-source");
  TemporaryDirectory targetDirectory("qixi-core-target");
  const std::filesystem::path exportPath = sourceDirectory.path / "active.qixi-core-store";
  const std::filesystem::path corruptPath = sourceDirectory.path / "corrupt.qixi-core-store";
  UniformEvaluator evaluator;

  BackendWorker source;
  installEvaluatorSelector(source, evaluator);
  std::string error;
  require(source.setStoreDirectory(sourceDirectory.path.string(), &error), "setStoreDirectory source");
  require(execute(source, RequestKind::boot, BootRequest{}).ok, "boot source");
  require(selectEngine(source, ModelId::b6).ok, "select b6");

  BackendResult firstMove = play(source, pointToMove(3, 3), 100, RootRef::nodeRef(0));
  require(firstMove.ok && firstMove.snapshot.has_value(), "first move");
  const uint64_t firstLineage = firstMove.snapshot->rootLineageHash;
  source.runSearchPlayouts(48);
  BackendResult b6Analyzed = source.latestSnapshot();
  require(b6Analyzed.snapshot.has_value() && b6Analyzed.snapshot->rootVisits >= 48, "b6 visits");
  const uint64_t b6Visits = b6Analyzed.snapshot->rootVisits;
  const uint64_t b6Lineage = b6Analyzed.snapshot->rootLineageHash;
  require(b6Lineage == firstLineage, "b6 lineage");

  // Second engine keeps local multi-engine parking, but export is active-only.
  require(selectEngine(source, ModelId::b18nbt).ok, "select b18");
  BackendResult secondMove = play(
    source,
    pointToMove(15, 15),
    101,
    RootRef::lineageRef(firstLineage)
  );
  require(secondMove.ok && secondMove.snapshot.has_value(), "second move");
  const uint64_t secondLineage = secondMove.snapshot->rootLineageHash;
  source.runSearchPlayouts(24);
  const uint64_t b18Visits = source.latestSnapshot().snapshot->rootVisits;
  require(b18Visits >= 24, "b18 visits");

  // Product export: active store only via fopen("wb") + fwrite of the memory image.
  ExportAnalysisStateRequest exportRequest;
  exportRequest.path = exportPath.string();
  require(execute(source, RequestKind::exportAnalysisState, exportRequest).ok, "export active store");
  require(std::filesystem::file_size(exportPath) > 0, "export file non-empty");
  {
    std::string decodeError;
    auto exported = MCTSStore::deserialize(readBytes(exportPath), &decodeError);
    require(exported.has_value(), ("export deserialize: " + decodeError).c_str());
    require(exported->analysisKey().modelId == ModelId::b18nbt, "export is active b18 store");
  }

  std::filesystem::copy_file(exportPath, corruptPath);
  {
    std::fstream file(corruptPath, std::ios::in | std::ios::out | std::ios::binary);
    require(static_cast<bool>(file), "open corrupt copy");
    file.seekg(32);
    char byte = 0;
    file.read(&byte, 1);
    byte ^= 0x40;
    file.seekp(32);
    file.write(&byte, 1);
  }

  BackendWorker target;
  installEvaluatorSelector(target, evaluator);
  require(target.setStoreDirectory(targetDirectory.path.string(), &error), "setStoreDirectory target");
  require(execute(target, RequestKind::boot, BootRequest{}).ok, "boot target");
  ImportAnalysisStateRequest importRequest;
  importRequest.path = exportPath.string();
  BackendResult imported = execute(target, RequestKind::importAnalysisState, importRequest);
  require(imported.ok && imported.snapshot.has_value(), "import active store");
  require(imported.snapshot->rootLineageHash == secondLineage, "imported lineage");
  require(imported.snapshot->rootVisits == b18Visits, "imported visits");

  // Imported package is a single active-store blob (may coexist with a pre-import
  // checkpoint file written during install).
  bool sawImportedB18 = false;
  std::string importedActiveFilename;
  for(const auto& item : std::filesystem::directory_iterator(targetDirectory.path)) {
    if(item.path().extension() != ".qixi-core-store")
      continue;
    std::string decodeError;
    auto decoded = MCTSStore::deserialize(readBytes(item.path()), &decodeError);
    require(decoded.has_value(), "imported on-disk store decodes");
    if(decoded->analysisKey().modelId == ModelId::b18nbt) {
      sawImportedB18 = true;
      importedActiveFilename = item.path().filename().string();
    }
  }
  require(sawImportedB18, "imported b18 store present on disk");

  // Corrupt package must not clobber a good imported state.
  const uint64_t beforeCorruptImport = imported.snapshot->rootVisits;
  importRequest.path = corruptPath.string();
  BackendResult corrupt = execute(target, RequestKind::importAnalysisState, importRequest);
  require(!corrupt.ok, "corrupt import rejected");
  require(
    target.latestSnapshot().snapshot.has_value() &&
      target.latestSnapshot().snapshot->rootVisits == beforeCorruptImport,
    "good state preserved after corrupt import"
  );

  // Pre-existing garbage at a store path must never be overwritten: import rekeys
  // to a free game id and succeeds, leaving the seed file intact.
  TemporaryDirectory collisionDirectory("qixi-core-collision");
  BackendWorker collisionTarget;
  installEvaluatorSelector(collisionTarget, evaluator);
  require(collisionTarget.setStoreDirectory(collisionDirectory.path.string(), &error), "collision dir");
  require(execute(collisionTarget, RequestKind::boot, BootRequest{}).ok, "boot collision");
  const auto seedPath = collisionDirectory.path / importedActiveFilename;
  {
    std::ofstream collision(seedPath, std::ios::binary);
    require(static_cast<bool>(collision), "seed collision file");
    collision << "preexisting-store";
  }
  importRequest.path = exportPath.string();
  BackendResult collision = execute(
    collisionTarget, RequestKind::importAnalysisState, importRequest
  );
  require(collision.ok, "import rekeys past occupied store path");
  require(std::filesystem::exists(seedPath), "seed path still exists");
  {
    const auto seedBytes = readBytes(seedPath);
    const std::string seedText(seedBytes.begin(), seedBytes.end());
    require(seedText == "preexisting-store", "seed file must not be overwritten");
  }

  // Source still has the live b18 tree after export.
  require(source.latestSnapshot().snapshot->rootVisits == b18Visits, "source visits unchanged");
  require(source.latestSnapshot().snapshot->rootLineageHash == secondLineage, "source lineage");
  (void)b6Visits;
}

} // namespace

int main() {
  testActiveStoreExportImportRoundTrip();
  std::cout << "qixi_core_store_bundle passed\n";
  return 0;
}
