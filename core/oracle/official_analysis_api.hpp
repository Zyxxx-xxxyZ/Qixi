#pragma once

#include "host_nn_bridge.hpp"
#include "qixi/analysis_api.hpp"

#include <memory>
#include <string>

namespace qixi::oracle {

// Official analysis backend for the oracle harness.
// - Default: upstream Search + PUCT (setPosition, runWholeSearch).
// - TEST-ONLY (enableTestNnPolicyOnlySelection): NN-policy-only selection via a
//   fresh MCTSStore each root (not used in production). See
//   docs/oracle-test-discrepancies.md.
std::unique_ptr<analysis::AnalysisEngine> createOfficialAnalysisEngine(HostNNContext* ctx);

} // namespace qixi::oracle
