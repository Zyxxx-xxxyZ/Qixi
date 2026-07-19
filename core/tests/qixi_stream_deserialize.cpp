#include "qixi/mcts.hpp"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <string>
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

[[noreturn]] void fail(const char* message) {
  std::fprintf(stderr, "qixi_stream_deserialize failed: %s\n", message);
  std::exit(1);
}

} // namespace

int main() {
  Rules rules;
  AnalysisKey key = makeKey(1, ModelId::b6, rules, 0);
  SearchParams params;
  BoardState board = BoardLogic::emptyBoard(Color::black);
  MCTSStore store = MCTSStore::create(board, rules, key, params);
  UniformEvaluator eval;
  store.setEvaluator(&eval);
  for(int i = 0; i < 200; ++i)
    store.runPlayout();

  const std::vector<uint8_t> bytes = store.serialize();
  if(bytes.empty())
    fail("serialize produced empty blob");
  if(bytes.size() < 32)
    fail("serialize produced undersized blob");

  // In-memory path with optional progress still succeeds (diagnostic only).
  {
    std::vector<std::string> memPhases;
    double memLast = -1.0;
    auto memProgress = [&](const MCTSStore::DeserializeProgress& p) {
      if(memPhases.empty() || memPhases.back() != p.phase)
        memPhases.push_back(p.phase);
      if(p.fraction + 1e-9 < memLast)
        fail("in-memory progress went backwards");
      memLast = p.fraction;
      if(p.fraction < 0.0 || p.fraction > 1.0 + 1e-9)
        fail("in-memory progress out of range");
    };
    std::string memError;
    auto memLoaded = MCTSStore::deserialize(bytes, &memError, memProgress);
    if(!memLoaded.has_value())
      fail(("in-memory deserialize failed: " + memError).c_str());
    if(memLast < 0.99)
      fail("in-memory progress did not complete");
    if(memLoaded->memoryStats().nodeCount != store.memoryStats().nodeCount)
      fail("in-memory node count mismatch");
  }

  const std::filesystem::path path =
    std::filesystem::temp_directory_path() /
    ("qixi-oneshot-deserialize-test-" +
     std::to_string(std::chrono::high_resolution_clock::now().time_since_epoch().count()) +
     ".qixi-core-store");

  // Product path: one-shot persistToFile / loadFromFile (no streaming progress).
  {
    std::string writeError;
    if(!store.persistToFile(path.string(), &writeError))
      fail(("persistToFile failed: " + writeError).c_str());
  }
  if(!std::filesystem::exists(path) || std::filesystem::file_size(path) < 32)
    fail("temp store file missing or undersized after one-shot write");

  std::string error;
  auto loaded = MCTSStore::loadFromFile(path.string(), 64ULL * 1024ULL * 1024ULL, &error);
  if(!loaded.has_value()) {
    std::fprintf(stderr, "loadFromFile failed: %s\n", error.c_str());
    std::filesystem::remove(path);
    return 1;
  }
  // deserializeFromFile is an alias that ignores progress.
  auto loadedAlias = MCTSStore::deserializeFromFile(
    path.string(),
    64ULL * 1024ULL * 1024ULL,
    &error,
    [](const MCTSStore::DeserializeProgress&) {
      fail("file load must not stream progress callbacks");
    }
  );
  if(!loadedAlias.has_value())
    fail(("deserializeFromFile alias failed: " + error).c_str());

  if(loaded->memoryStats().nodeCount < 1)
    fail("loaded store has no nodes");
  if(loaded->memoryStats().nodeCount != store.memoryStats().nodeCount)
    fail("loaded node count mismatch");
  if(loaded->currentRoot() != store.currentRoot())
    fail("loaded root mismatch");

  std::filesystem::remove(path);
  std::printf("qixi_stream_deserialize passed (one-shot file I/O)\n");
  return 0;
}
