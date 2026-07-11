#include "qixi/analysis_api.hpp"

#include <cassert>
#include <iostream>
#include <string>

using namespace qixi;

int main() {
  core::UniformEvaluator eval;
  auto engine = analysis::createCustomAnalysisEngine(&eval);
  assert(engine != nullptr);
  assert(std::string(engine->name()) == "custom");

  analysis::GameLine line;
  line.komi = 7.5f;
  line.rules.komi = 7.5f;
  // Empty opening: B D4, W Q16, B C3 style
  line.moves.push_back({core::pointToMove(3, 3), core::Color::black});
  line.moves.push_back({core::pointToMove(15, 15), core::Color::white});
  line.moves.push_back({core::pointToMove(2, 2), core::Color::black});

  std::string err;
  assert(engine->loadLine(line, &err));
  assert(engine->lineLength() == 3);
  assert(engine->currentRootPly() == 0);

  // Root change API
  assert(engine->setRootPly(2, &err));
  assert(engine->currentRootPly() == 2);
  assert(engine->setRootPly(0, &err));

  // Set analyses + run
  engine->setAdditionalAnalyses(32);
  assert(engine->additionalAnalysesBudget() == 32);
  const uint64_t executed = engine->runAnalyses(&err);
  assert(executed == 32);
  assert(engine->rootAnalysisCount() == 32);

  const analysis::RootObservation obs = engine->observeRoot();
  assert(obs.analysisCount == 32);
  assert(obs.winrate >= 0.0f && obs.winrate <= 1.0f);

  // Absolute target
  const uint64_t more = engine->runAnalysesUntilTotal(48, &err);
  assert(more == 16);
  assert(engine->rootAnalysisCount() == 48);

  // Root transfer then query analyses on that root
  assert(engine->setRootPly(1, &err));
  const uint64_t before = engine->rootAnalysisCount();
  engine->setAdditionalAnalyses(16);
  engine->runAnalyses(&err);
  assert(engine->rootAnalysisCount() >= before + 16 || engine->rootAnalysisCount() > before);

  std::cout << "qixi_analysis_api_smoke: ok\n";
  return 0;
}
