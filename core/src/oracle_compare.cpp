#include "qixi/oracle_compare.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>

namespace qixi::core {

void OracleCompareResult::add(std::string field, std::string detail) {
  ok = false;
  issues.push_back(OracleCompareIssue{std::move(field), std::move(detail)});
}

OracleRootReport oracleReportFromSnapshot(const RootSnapshot& snapshot, std::string label) {
  OracleRootReport report;
  report.label = std::move(label);
  report.rootVisits = snapshot.rootVisits;
  report.rootWinrate = snapshot.rootWinrate;
  report.rootScoreMean = snapshot.rootScoreMean;
  report.hasOwnership = snapshot.hasOwnership;
  report.ownership = snapshot.ownership;
  report.candidates.reserve(snapshot.candidates.size());
  for(const CandidateSnapshot& candidate : snapshot.candidates) {
    OracleCandidate entry;
    entry.move = candidate.move;
    entry.visits = candidate.visits;
    entry.prior = candidate.prior;
    entry.winrate = candidate.winrate;
    entry.scoreMean = candidate.scoreMean;
    entry.utility = candidate.utility;
    report.candidates.push_back(entry);
  }
  std::sort(
    report.candidates.begin(),
    report.candidates.end(),
    [](const OracleCandidate& a, const OracleCandidate& b) {
      return a.move < b.move;
    }
  );
  return report;
}

bool oracleNear(double expected, double actual, const OracleTolerances& tol) {
  if(!std::isfinite(expected) || !std::isfinite(actual))
    return std::isfinite(expected) == std::isfinite(actual) && expected == actual;
  const double diff = std::fabs(expected - actual);
  const double scale = std::max(std::fabs(expected), std::fabs(actual));
  return diff <= tol.atol + tol.rtol * scale;
}

namespace {

std::string formatMove(Move move) {
  if(move == kMovePass)
    return "pass";
  if(move >= kBoardArea)
    return "invalid:" + std::to_string(move);
  const Point point = moveToPoint(move);
  return std::to_string(point.x) + "," + std::to_string(point.y);
}

std::string formatDouble(double value) {
  std::ostringstream out;
  out.setf(std::ios::fixed);
  out.precision(6);
  out << value;
  return out.str();
}

void compareFloatField(
  OracleCompareResult& result,
  const std::string& field,
  double expected,
  double actual,
  const OracleTolerances& tol
) {
  if(!oracleNear(expected, actual, tol)) {
    result.add(
      field,
      "expected " + formatDouble(expected) + " actual " + formatDouble(actual)
    );
  }
}

} // namespace

OracleCompareResult compareOracleReports(
  const OracleRootReport& expected,
  const OracleRootReport& actual,
  const OracleTolerances& tol
) {
  OracleCompareResult result;
  if(tol.requireExactVisits && expected.rootVisits != actual.rootVisits) {
    result.add(
      "rootVisits",
      "expected " + std::to_string(expected.rootVisits) +
        " actual " + std::to_string(actual.rootVisits)
    );
  }
  compareFloatField(result, "rootWinrate", expected.rootWinrate, actual.rootWinrate, tol);
  compareFloatField(result, "rootScoreMean", expected.rootScoreMean, actual.rootScoreMean, tol);

  if(expected.hasOwnership != actual.hasOwnership) {
    result.add(
      "hasOwnership",
      "expected " + std::string(expected.hasOwnership ? "true" : "false") +
        " actual " + std::string(actual.hasOwnership ? "true" : "false")
    );
  } else if(expected.hasOwnership) {
    for(int i = 0; i < kOwnershipDim; ++i) {
      if(!oracleNear(expected.ownership[i], actual.ownership[i], tol)) {
        result.add(
          "ownership[" + std::to_string(i) + "]",
          "expected " + formatDouble(expected.ownership[i]) +
            " actual " + formatDouble(actual.ownership[i])
        );
        // Cap ownership spam; one mismatch already proves divergence.
        if(result.issues.size() >= 8)
          break;
      }
    }
  }

  if(expected.candidates.size() != actual.candidates.size()) {
    result.add(
      "candidateCount",
      "expected " + std::to_string(expected.candidates.size()) +
        " actual " + std::to_string(actual.candidates.size())
    );
    return result;
  }

  for(size_t i = 0; i < expected.candidates.size(); ++i) {
    const OracleCandidate& exp = expected.candidates[i];
    const OracleCandidate& act = actual.candidates[i];
    const std::string prefix = "candidate[" + formatMove(exp.move) + "]";
    if(exp.move != act.move) {
      result.add(
        prefix + ".move",
        "expected " + formatMove(exp.move) + " actual " + formatMove(act.move)
      );
      continue;
    }
    if(tol.requireExactVisits && exp.visits != act.visits) {
      result.add(
        prefix + ".visits",
        "expected " + std::to_string(exp.visits) +
          " actual " + std::to_string(act.visits)
      );
    }
    compareFloatField(result, prefix + ".prior", exp.prior, act.prior, tol);
    compareFloatField(result, prefix + ".winrate", exp.winrate, act.winrate, tol);
    compareFloatField(result, prefix + ".scoreMean", exp.scoreMean, act.scoreMean, tol);
    compareFloatField(result, prefix + ".utility", exp.utility, act.utility, tol);
  }
  return result;
}

std::string formatOracleCompareResult(const OracleCompareResult& result, size_t maxIssues) {
  if(result.ok)
    return "ok";
  std::ostringstream out;
  out << result.issues.size() << " issue(s)";
  const size_t limit = std::min(maxIssues, result.issues.size());
  for(size_t i = 0; i < limit; ++i) {
    out << "; " << result.issues[i].field << ": " << result.issues[i].detail;
  }
  if(result.issues.size() > limit)
    out << "; ...";
  return out.str();
}

} // namespace qixi::core
