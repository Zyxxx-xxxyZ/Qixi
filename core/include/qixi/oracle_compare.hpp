#pragma once

#include "qixi/mcts.hpp"

#include <cmath>
#include <optional>
#include <string>
#include <vector>

namespace qixi::core {

// Tolerances from docs/grok-4.5-handoff.md §15 for official-vs-custom comparison.
// Exact integer visit counts should match when both sides use the same playout budget
// and a deterministic shared evaluator; floating fields use relative/absolute bands.
struct OracleTolerances {
  double atol = 1e-4;
  double rtol = 1e-3;
  bool requireExactVisits = true;
};

struct OracleCandidate {
  Move move = kMovePass;
  uint64_t visits = 0;
  float prior = 0.0f;
  float winrate = 0.0f;
  float scoreMean = 0.0f;
  float utility = 0.0f;
};

// One root observation for oracle comparison. Both the custom core and the future
// official KataGo side must produce this shape.
struct OracleRootReport {
  std::string label;
  uint64_t rootVisits = 0;
  float rootWinrate = 0.0f;
  float rootScoreMean = 0.0f;
  std::vector<OracleCandidate> candidates;
  std::array<float, kOwnershipDim> ownership{};
  bool hasOwnership = false;
};

struct OracleCompareIssue {
  std::string field;
  std::string detail;
};

struct OracleCompareResult {
  bool ok = true;
  std::vector<OracleCompareIssue> issues;

  void add(std::string field, std::string detail);
};

// Convert a custom-core snapshot into the oracle report shape. Candidates are sorted
// by move index so order does not affect comparison.
OracleRootReport oracleReportFromSnapshot(const RootSnapshot& snapshot, std::string label);

// Numeric comparison used for winrate / score / ownership / prior / utility.
bool oracleNear(double expected, double actual, const OracleTolerances& tol);

// Compare two root reports under the handoff tolerances. On failure, issues list
// every mismatched field (bounded) for debugging search divergence.
OracleCompareResult compareOracleReports(
  const OracleRootReport& expected,
  const OracleRootReport& actual,
  const OracleTolerances& tol = {}
);

// Compact single-line summary suitable for assert messages and CI logs.
std::string formatOracleCompareResult(const OracleCompareResult& result, size_t maxIssues = 12);

} // namespace qixi::core
