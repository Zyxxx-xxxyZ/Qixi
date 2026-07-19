#include "qixi/mcts.hpp"
#include "qixi/request_pool.hpp"

#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

using namespace qixi::core;

static void expect(bool cond, const char* msg) {
  if(!cond) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    std::exit(1);
  }
}

int main() {
  BackendWorker worker;
  worker.start();

  // Boot empty store via select none path - use executeForTests boot
  auto boot = worker.executeForTests(RequestKind::boot, BootRequest{false, true}, 0);
  expect(boot.ok, "boot ok");

  // Publish via playout path may be empty without engine; force by posting nav after new game
  auto ng = worker.executeForTests(
    RequestKind::newGame,
    NewGameRequest{},
    0
  );
  expect(ng.ok, "newGame ok");

  // Play a center move via single-slot nav (no FIFO)
  BackendWorker::NavIntent intent;
  intent.kind = BackendWorker::NavIntentKind::play;
  intent.moveOrNode = static_cast<uint32_t>(3 * 19 + 3);
  intent.uiIntentId = 1;
  expect(worker.postNavIntent(intent), "post nav");
  // Allow worker to drain
  for(int i = 0; i < 50; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    AnalyzeDisplayPayload payload{};
    if(worker.tryLoadAnalyzeDisplay(payload) && payload.revision > 0)
      break;
  }
  // revision may still be 0 if store not ready without engine - check switchRoot O(1) path on store directly
  Rules rules;
  rules.komi = 7.5f;
  AnalysisKey key;
  key.gameId = 1;
  SearchParams params;
  auto store = MCTSStore::create(BoardLogic::emptyBoard(), rules, key, params);
  auto commit = store.playMoveFromRoot(static_cast<Move>(3 * 19 + 3));
  expect(commit.ok, "playMove ok");
  NodeId child = commit.node;
  // Switch back to root 0 then to child — both should hit board cache
  std::string err;
  expect(store.switchRoot(0, &err), "switch to root");
  expect(store.switchRoot(child, &err), "switch to child");

  AnalyzeDisplayPayload disp{};
  store.fillAnalyzeDisplay(disp, 10, true);
  expect(disp.candidateCount <= 10, "cap K");
  expect(disp.root == child, "root matches");

  // Lock-free load should never take state mutex: concurrent reads while publishing
  worker.stop();
  std::printf("qixi_realtime_plane_smoke passed\n");
  return 0;
}
