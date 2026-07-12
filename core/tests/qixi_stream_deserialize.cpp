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

  // In-memory path with progress must also succeed and be monotonic.
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
    ("qixi-stream-deserialize-test-" +
     std::to_string(std::chrono::high_resolution_clock::now().time_since_epoch().count()) +
     ".qixi-core-store");
  {
    FILE* f = std::fopen(path.string().c_str(), "wb");
    if(f == nullptr)
      fail("could not open temp file for writing");
    const size_t written = std::fwrite(bytes.data(), 1, bytes.size(), f);
    if(std::fclose(f) != 0)
      fail("could not close temp file after writing");
    if(written != bytes.size())
      fail("short write of serialized store");
  }
  if(!std::filesystem::exists(path) || std::filesystem::file_size(path) != bytes.size())
    fail("temp store file missing or wrong size after write");

  std::vector<std::string> phases;
  double lastFraction = -1.0;
  auto progress = [&](const MCTSStore::DeserializeProgress& p) {
    if(phases.empty() || phases.back() != p.phase)
      phases.push_back(p.phase);
    if(p.fraction + 1e-9 < lastFraction)
      fail("file progress went backwards");
    lastFraction = p.fraction;
    if(p.fraction < 0.0 || p.fraction > 1.0 + 1e-9)
      fail("file progress out of range");
  };

  std::string error;
  auto loaded = MCTSStore::deserializeFromFile(path.string(), 64ULL * 1024ULL * 1024ULL, &error, progress);
  if(!loaded.has_value()) {
    std::fprintf(stderr, "deserializeFromFile failed: %s\n", error.c_str());
    std::filesystem::remove(path);
    return 1;
  }
  if(lastFraction < 0.99)
    fail("file progress did not complete");
  if(phases.empty())
    fail("no progress phases reported");
  bool sawReading = false;
  bool sawVerify = false;
  bool sawParse = false;
  bool sawComplete = false;
  for(const auto& phase : phases) {
    if(phase == "reading")
      sawReading = true;
    if(phase == "verifying")
      sawVerify = true;
    if(phase == "parsing_nodes" || phase == "parsing_header")
      sawParse = true;
    if(phase == "complete")
      sawComplete = true;
  }
  if(!sawReading)
    fail("missing reading phase");
  if(!sawVerify)
    fail("missing verifying phase");
  if(!sawParse)
    fail("missing parse phase");
  if(!sawComplete)
    fail("missing complete phase");
  if(loaded->memoryStats().nodeCount < 1)
    fail("loaded store has no nodes");
  if(loaded->memoryStats().nodeCount != store.memoryStats().nodeCount)
    fail("loaded node count mismatch");
  if(loaded->currentRoot() != store.currentRoot())
    fail("loaded root mismatch");

  std::filesystem::remove(path);
  return 0;
}
