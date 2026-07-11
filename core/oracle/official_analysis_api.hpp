#pragma once

#include "host_nn_bridge.hpp"
#include "qixi/analysis_api.hpp"

#include <memory>
#include <string>

namespace qixi::oracle {

// Official lightvector/KataGo Search backend (no persistence — upstream has none).
// Root changes use stock setPosition; visit budgets via maxVisits/maxPlayouts.
std::unique_ptr<analysis::AnalysisEngine> createOfficialAnalysisEngine(HostNNContext* ctx);

} // namespace qixi::oracle
