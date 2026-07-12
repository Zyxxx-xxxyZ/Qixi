#include "qixi/request_pool.hpp"

#include <cassert>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <string>

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

void installEvaluator(BackendWorker& worker, UniformEvaluator& evaluator) {
  worker.setEngineSelector([&](ModelId model, Evaluator*& selected, std::string&) {
    selected = model == ModelId::none ? nullptr : &evaluator;
    return true;
  });
}

} // namespace

int main() {
  TemporaryDirectory dir("qixi-mem-pressure");
  UniformEvaluator evaluator;
  BackendWorker worker;
  installEvaluator(worker, evaluator);
  std::string error;
  assert(worker.setStoreDirectory(dir.path.string(), &error));
  assert(execute(worker, RequestKind::boot, BootRequest{}).ok);

  SelectEngineRequest select;
  select.modelId = ModelId::b6;
  assert(execute(worker, RequestKind::selectEngine, select).ok);

  PlayMoveRequest play;
  play.move = pointToMove(3, 3);
  play.uiIntentId = 42;
  play.parentRootRef = RootRef::nodeRef(0);
  auto played = execute(worker, RequestKind::playMove, play);
  assert(played.ok);
  assert(played.snapshot.has_value());
  const uint64_t lineage = played.snapshot->rootLineageHash;
  worker.runSearchPlayouts(48);
  auto before = worker.latestLightSnapshot();
  assert(before.ok && before.snapshot.has_value());
  assert(before.snapshot->rootVisits >= 48);
  const uint64_t visits = before.snapshot->rootVisits;

  // Poll must not crash and must not rehydrate after unload — first check resident.
  assert(before.message.find("snapshot") != std::string::npos ||
         before.message.find("light") != std::string::npos);

  RelieveMemoryPressureRequest hard;
  hard.level = 1;
  auto unloaded = execute(worker, RequestKind::relieveMemoryPressure, hard);
  assert(unloaded.ok);
  assert(unloaded.message.find("unloaded") != std::string::npos);

  // Snapshot poll: ok, but store not resident (no rehydrate).
  auto poll = worker.latestLightSnapshot();
  assert(poll.ok);
  assert(!poll.snapshot.has_value());
  assert(poll.message.find("not resident") != std::string::npos);

  // Disk checkpoint must exist.
  bool sawStoreFile = false;
  for(const auto& item : std::filesystem::directory_iterator(dir.path)) {
    if(item.path().extension() == ".qixi-core-store") {
      sawStoreFile = true;
      assert(std::filesystem::file_size(item.path()) > 32);
    }
  }
  assert(sawStoreFile);
  assert(std::filesystem::exists(dir.path / "active-store.index"));

  // Mutation rehydrates.
  JumpToNodeRequest jump;
  jump.targetRootRef = RootRef::lineageRef(lineage);
  auto jumped = execute(worker, RequestKind::jumpToNode, jump);
  assert(jumped.ok);
  assert(jumped.snapshot.has_value());
  assert(jumped.snapshot->rootVisits == visits);
  assert(jumped.snapshot->rootLineageHash == lineage);

  // Soft level only checkpoints and keeps store resident.
  hard.level = 0;
  auto soft = execute(worker, RequestKind::relieveMemoryPressure, hard);
  assert(soft.ok);
  auto afterSoft = worker.latestLightSnapshot();
  assert(afterSoft.ok && afterSoft.snapshot.has_value());

  // Without store directory, hard unload must refuse (would lose analysis).
  BackendWorker noDir;
  installEvaluator(noDir, evaluator);
  assert(execute(noDir, RequestKind::boot, BootRequest{}).ok);
  select.modelId = ModelId::b6;
  assert(execute(noDir, RequestKind::selectEngine, select).ok);
  noDir.runSearchPlayouts(8);
  hard.level = 1;
  auto refused = execute(noDir, RequestKind::relieveMemoryPressure, hard);
  assert(!refused.ok);
  assert(refused.message.find("store directory") != std::string::npos);
  auto stillThere = noDir.latestLightSnapshot();
  assert(stillThere.ok && stillThere.snapshot.has_value());

  std::cout << "qixi_memory_pressure_relief passed\n";
  return 0;
}
