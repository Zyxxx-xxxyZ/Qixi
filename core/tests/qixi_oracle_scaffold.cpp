// Oracle harness scaffold (Milestone 2, first fixed-root cases).
//
// Scope today:
//   1. Deterministic custom-core replay under UniformEvaluator (same seed/params).
//   2. Export → import → continue matches a continuous custom-core run.
//   3. Fixed-root scenario protocol that the future official KataGo side must mirror.
//
// Not yet proven:
//   Official KataGo Search equivalence. Linking Search + the same NN model is the
//   next harness step (see comments on OfficialKataGoOracle below). Do not treat
//   these tests as official-search equivalence evidence.

#include "qixi/oracle_compare.hpp"

#include <cassert>
#include <iostream>
#include <string>
#include <vector>

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

// Fixed scenario used as the first official-vs-custom comparison case once the
// KataGo-linked runner exists.
struct FixedRootScenario {
  Rules rules;
  SearchParams params;
  uint32_t playouts = 64;
  std::string label = "fixed-root-empty-64";
};

FixedRootScenario makeFirstFixedRootScenario() {
  FixedRootScenario scenario;
  scenario.rules = Rules{};
  scenario.rules.komi = 7.5f;
  scenario.params = SearchParams{};
  scenario.params.cpuct = 1.1f;
  scenario.params.fpuValue = 0.0f;
  scenario.params.rootNoise = 0.0f; // disable root noise for reproducible oracle
  scenario.params.rootNoiseWeight = 0.0f;
  scenario.params.winLossUtilityFactor = 1.0f;
  scenario.params.staticScoreUtilityFactor = 0.0f;
  scenario.params.dynamicScoreUtilityFactor = 0.0f;
  scenario.params.seed = 0x4f52434c45ULL; // "ORCLE"
  scenario.playouts = 64;
  scenario.label = "fixed-root-empty-64";
  return scenario;
}

MCTSStore makeStore(const FixedRootScenario& scenario, UniformEvaluator& evaluator) {
  AnalysisKey key = makeKey(1, ModelId::b6, scenario.rules, 0);
  MCTSStore store = MCTSStore::create(
    BoardLogic::emptyBoard(Color::black),
    scenario.rules,
    key,
    scenario.params
  );
  store.setEvaluator(&evaluator);
  return store;
}

OracleRootReport runFixedRootCustom(const FixedRootScenario& scenario) {
  UniformEvaluator evaluator;
  MCTSStore store = makeStore(scenario, evaluator);
  store.runPlayouts(scenario.playouts);
  return oracleReportFromSnapshot(store.snapshot(), scenario.label + "/custom");
}

void requireMatch(
  const OracleRootReport& expected,
  const OracleRootReport& actual,
  const OracleTolerances& tol,
  const char* context
) {
  const OracleCompareResult result = compareOracleReports(expected, actual, tol);
  if(!result.ok) {
    std::cerr << "oracle mismatch in " << context << ": "
              << formatOracleCompareResult(result) << "\n";
  }
  assert(result.ok);
}

void testFixedRootDeterminism() {
  const FixedRootScenario scenario = makeFirstFixedRootScenario();
  const OracleRootReport a = runFixedRootCustom(scenario);
  const OracleRootReport b = runFixedRootCustom(scenario);

  assert(a.rootVisits == scenario.playouts);
  assert(!a.candidates.empty());
  assert(a.hasOwnership);

  OracleTolerances exact;
  exact.atol = 0.0;
  exact.rtol = 0.0;
  exact.requireExactVisits = true;
  requireMatch(a, b, exact, "fixed-root determinism");
  std::cout << "ok fixed-root determinism visits=" << a.rootVisits
            << " candidates=" << a.candidates.size() << "\n";
}

void testFixedRootExportImportContinuation() {
  const FixedRootScenario scenario = makeFirstFixedRootScenario();
  const uint32_t firstHalf = scenario.playouts / 2;
  const uint32_t secondHalf = scenario.playouts - firstHalf;

  UniformEvaluator evaluatorA;
  MCTSStore continuous = makeStore(scenario, evaluatorA);
  continuous.runPlayouts(scenario.playouts);
  const OracleRootReport continuousReport =
    oracleReportFromSnapshot(continuous.snapshot(), scenario.label + "/continuous");

  UniformEvaluator evaluatorB;
  MCTSStore first = makeStore(scenario, evaluatorB);
  first.runPlayouts(firstHalf);
  std::string exportError;
  const std::vector<uint8_t> bytes = first.serialize();
  assert(!bytes.empty());

  std::string importError;
  auto restored = MCTSStore::deserialize(bytes, &importError);
  assert(restored.has_value());
  restored->setEvaluator(&evaluatorB);
  restored->runPlayouts(secondHalf);
  const OracleRootReport restoredReport =
    oracleReportFromSnapshot(restored->snapshot(), scenario.label + "/export-import");

  // Same seed and playout budget should yield identical custom-core trajectories even
  // when a checkpoint clears the live store mid-run.
  OracleTolerances exact;
  exact.atol = 0.0;
  exact.rtol = 0.0;
  exact.requireExactVisits = true;
  requireMatch(continuousReport, restoredReport, exact, "export-import continuation");
  std::cout << "ok fixed-root export-import continuation\n";
}

void testRootSwitchIsolationStillRecordedInOracleShape() {
  // Exercises the scenario language for ancestor/descendant roots that the official
  // harness must also run. This is not official equivalence; it locks the custom
  // report shape after a root switch.
  const FixedRootScenario base = makeFirstFixedRootScenario();
  UniformEvaluator evaluator;
  MCTSStore store = makeStore(base, evaluator);

  const Move blackOpen = pointToMove(3, 3);
  const Move whiteOpen = pointToMove(15, 15);
  assert(store.playMoveFromRoot(blackOpen).ok);
  assert(store.playMoveFromRoot(whiteOpen).ok);
  store.runPlayouts(32);
  const NodeId descendantRoot = store.currentRoot();
  assert(store.switchRoot(0, nullptr)); // initial empty board node is id 0
  store.runPlayouts(16);
  const OracleRootReport ancestorReport =
    oracleReportFromSnapshot(store.snapshot(), "root-switch/ancestor");

  assert(store.switchRoot(descendantRoot, nullptr));
  const OracleRootReport descendantReport =
    oracleReportFromSnapshot(store.snapshot(), "root-switch/descendant");

  assert(ancestorReport.rootVisits >= 16);
  assert(descendantReport.rootVisits >= 32);
  // Different roots must emit independent reports (not a shared flattened view).
  assert(ancestorReport.label != descendantReport.label);

  OracleTolerances tol;
  // Self-compare sanity for the comparator.
  requireMatch(ancestorReport, ancestorReport, tol, "self ancestor");
  requireMatch(descendantReport, descendantReport, tol, "self descendant");
  std::cout << "ok root-switch oracle report shape "
            << "ancestorVisits=" << ancestorReport.rootVisits
            << " descendantVisits=" << descendantReport.rootVisits << "\n";
}

// Placeholder for the official side. When QIXI_ORACLE_WITH_KATAGO is implemented,
// this should:
//   1. Load the same model file and rules/komi/noise/seed/playout budget.
//   2. Construct KataGo Search with numSearchThreads=1 and aligned SearchParams.
//   3. setPosition / runWholeSearch for the fixed-root scenario.
//   4. Extract root visits, per-move visit distribution, winrate, score mean, ownership
//      into OracleRootReport (same move indexing as qixi core: 0..360 + pass=361).
//   5. compareOracleReports(official, custom, handoffTolerances).
//
// Until that link exists, the scaffold refuses to claim equivalence.
struct OfficialKataGoOracle {
  static constexpr const char* status =
    "not_linked: official Search + shared NN model harness is the next milestone step";

  static std::optional<OracleRootReport> runFixedRoot(const FixedRootScenario&) {
    return std::nullopt;
  }
};

void testOfficialSideNotYetLinked() {
  const FixedRootScenario scenario = makeFirstFixedRootScenario();
  const auto official = OfficialKataGoOracle::runFixedRoot(scenario);
  assert(!official.has_value());
  const OracleRootReport custom = runFixedRootCustom(scenario);
  assert(custom.rootVisits == scenario.playouts);
  std::cout << "ok official oracle placeholder (" << OfficialKataGoOracle::status << ")\n";
  std::cout << "   custom baseline ready: label=" << custom.label
            << " visits=" << custom.rootVisits
            << " candidates=" << custom.candidates.size() << "\n";
}

} // namespace

int main() {
  testFixedRootDeterminism();
  testFixedRootExportImportContinuation();
  testRootSwitchIsolationStillRecordedInOracleShape();
  testOfficialSideNotYetLinked();
  std::cout << "qixi_oracle_scaffold: all scaffold checks passed "
               "(custom baselines only; official equivalence not claimed)\n";
  return 0;
}
