#pragma once

#include "host_nn_bridge.hpp"
#include "qixi/analysis_api.hpp"

#include <memory>
#include <string>

namespace qixi::oracle {

// Official KataGo Search backend implementing the same AnalysisEngine API.
// Uses existing Search APIs only (no Search.cpp edits):
//   setPosition, runWholeSearch, getRootVisits, getRootValues, getAnalysisData.
// Persistent-MCTS is intentionally OFF: root transfers via stock setPosition.
std::unique_ptr<analysis::AnalysisEngine> createOfficialAnalysisEngine(HostNNContext* ctx);

} // namespace qixi::oracle
