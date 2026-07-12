#include "QixiNativeKataGoCore.hpp"

#ifndef QIXI_ENABLE_NATIVE_KATAGO
#define QIXI_ENABLE_NATIVE_KATAGO 0
#endif

#if QIXI_ENABLE_NATIVE_KATAGO
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-literal-operator"
#endif
#include "core/config_parser.h"
#include "core/logger.h"
#include "core/rand.h"
#include "game/board.h"
#include "game/boardhistory.h"
#include "game/rules.h"
#include "neuralnet/nneval.h"
#include "neuralnet/nninputs.h"
#include "program/setup.h"
#include "search/searchparams.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#include <algorithm>
#include <array>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>
#endif

namespace qixi {
namespace {

#if !QIXI_ENABLE_NATIVE_KATAGO
NativeKataGoResult libraryNotLinkedResult() {
  return {
    NativeKataGoStatusCode::libraryNotLinked,
    "Native KataGo is not linked into this build.",
    "",
  };
}
#endif

#if QIXI_ENABLE_NATIVE_KATAGO

// Production search is core::MCTSStore only. This adapter loads KataGo weights and
// exposes NNEvaluator through LinkedCoreEvaluator. It must not construct AsyncBot
// or call Search::runWholeSearch / Search persistent-MCTS tombstones.

void qixiInitializeKataGoProcessOnce() {
  static std::once_flag initOnce;
  std::call_once(initOnce, []() {
    Board::initHash();
    ScoreValue::initTables();
  });
}

NativeKataGoResult nativeInvalidRequestResult(const std::string& message) {
  return {
    NativeKataGoStatusCode::invalidRequest,
    message,
    "",
  };
}

NativeKataGoResult nativeOKResult(const std::string& message, const std::string& responseJSON = "") {
  return {
    NativeKataGoStatusCode::ok,
    message,
    responseJSON,
  };
}

std::map<std::string, std::string> qixiNativeKataGoConfigMap(const NativeKataGoModelConfig& config) {
  std::map<std::string, std::string> values = {
    {"maxVisits", "64"},
    {"numSearchThreads", "1"},
    {"nnMaxBatchSize", "16"},
    {"nnCacheSizePowerOfTwo", "-1"},
    {"nnMutexPoolSizePowerOfTwo", "16"},
    {"nnRandomize", "false"},
    {"nnRandSeed", "qixi-native"},
    {"rootSymmetryPruning", "false"},
    {"wideRootNoise", "0.0"},
    {"conservativePass", "true"},
    {"numNNServerThreadsPerModel", config.coreMLPackagePaths.empty() ? "2" : "4"},
    {"metalDeviceToUseThread0", "0"},
    {"metalDeviceToUseThread1", "0"},
    {"metalDeviceToUseThread2", config.coreMLPackagePaths.empty() ? "0" : "100"},
    {"metalDeviceToUseThread3", config.coreMLPackagePaths.empty() ? "0" : "100"},
    {"metalUseFP16", "true"},
  };
  values["metalCoreMLPackagePathCount"] = std::to_string(config.coreMLPackagePaths.size());
  for(size_t i = 0; i<config.coreMLPackagePaths.size(); i++)
    values["metalCoreMLPackagePath" + std::to_string(i)] = config.coreMLPackagePaths[i];
  return values;
}

Rules qixiCoreRulesToKataGoRules(const core::Rules& qixiRules) {
  int koRule = Rules::KO_SIMPLE;
  switch(qixiRules.koRule) {
  case core::KoRule::simple: koRule = Rules::KO_SIMPLE; break;
  case core::KoRule::positional: koRule = Rules::KO_POSITIONAL; break;
  case core::KoRule::situational: koRule = Rules::KO_SITUATIONAL; break;
  }
  const int scoringRule = qixiRules.scoringRule == core::ScoringRule::area
    ? Rules::SCORING_AREA
    : Rules::SCORING_TERRITORY;
  int taxRule = Rules::TAX_NONE;
  switch(qixiRules.taxRule) {
  case core::TaxRule::none: taxRule = Rules::TAX_NONE; break;
  case core::TaxRule::seki: taxRule = Rules::TAX_SEKI; break;
  case core::TaxRule::all: taxRule = Rules::TAX_ALL; break;
  }
  int whiteHandicapBonusRule = Rules::WHB_N;
  switch(qixiRules.whiteHandicapBonusRule) {
  case core::WhiteHandicapBonusRule::zero: whiteHandicapBonusRule = Rules::WHB_ZERO; break;
  case core::WhiteHandicapBonusRule::n: whiteHandicapBonusRule = Rules::WHB_N; break;
  case core::WhiteHandicapBonusRule::nMinusOne: whiteHandicapBonusRule = Rules::WHB_N_MINUS_ONE; break;
  }
  return Rules(
    koRule,
    scoringRule,
    taxRule,
    qixiRules.multiStoneSuicideLegal,
    qixiRules.hasButton,
    whiteHandicapBonusRule,
    qixiRules.friendlyPassOk,
    qixiRules.komi
  );
}

Player qixiCorePlayer(core::Color color) {
  return color == core::Color::white ? P_WHITE : P_BLACK;
}

Loc qixiCoreMoveLoc(core::Move move) {
  if(move == core::kMovePass)
    return Board::PASS_LOC;
  const core::Point point = core::moveToPoint(move);
  return Location::getLoc(point.x, point.y, 19);
}

bool qixiBuildKataGoPositionFromCore(
  const core::BoardState& state,
  const core::Rules& coreRules,
  Board& board,
  BoardHistory& history,
  Player& nextPlayer
) {
  std::array<core::Color, core::kBoardArea> initialCells = state.cells;
  for(auto it = state.moves.rbegin(); it != state.moves.rend(); ++it) {
    const core::MoveRecord& record = *it;
    if(record.move == core::kMovePass)
      continue;
    initialCells[record.move] = core::Color::empty;
    for(core::Move stone : record.removedOwn) {
      if(stone != record.move)
        initialCells[stone] = record.pla;
    }
    for(core::Move stone : record.captured)
      initialCells[stone] = core::opposite(record.pla);
  }

  Board initialBoard(19, 19);
  std::vector<Move> placements;
  for(core::Move move = 0; move < core::kBoardArea; ++move) {
    if(initialCells[move] == core::Color::empty)
      continue;
    placements.emplace_back(qixiCoreMoveLoc(move), qixiCorePlayer(initialCells[move]));
  }
  if(!placements.empty() && !initialBoard.setStonesFailIfNoLibs(placements))
    return false;

  const Rules rules = qixiCoreRulesToKataGoRules(coreRules);
  const Player initialPlayer = state.moves.empty()
    ? qixiCorePlayer(state.nextPla)
    : qixiCorePlayer(state.moves.front().pla);
  BoardHistory rebuiltHistory(initialBoard, initialPlayer, rules, 0);
  rebuiltHistory.setAssumeMultipleStartingBlackMovesAreHandicap(false);
  Board rebuiltBoard = initialBoard;
  for(const core::MoveRecord& record : state.moves) {
    if(!rebuiltHistory.makeBoardMoveTolerant(
         rebuiltBoard,
         qixiCoreMoveLoc(record.move),
         qixiCorePlayer(record.pla),
         false
       ))
      return false;
  }

  for(core::Move move = 0; move < core::kBoardArea; ++move) {
    const Player expected = state.cells[move] == core::Color::empty
      ? C_EMPTY
      : qixiCorePlayer(state.cells[move]);
    if(rebuiltBoard.colors[qixiCoreMoveLoc(move)] != expected)
      return false;
  }
  board = rebuiltBoard;
  history = rebuiltHistory;
  nextPlayer = qixiCorePlayer(state.nextPla);
  return true;
}

class LinkedCoreEvaluator final : public core::Evaluator {
public:
  void configure(NNEvaluator* value, const SearchParams* paramsValue) {
    nnEval = value;
    searchParams = paramsValue;
  }

  bool available() const {
    return nnEval != nullptr && searchParams != nullptr;
  }

  bool evaluate(
    const core::BoardState& state,
    const core::Rules& rules,
    bool isRoot,
    core::LeafPayload& output
  ) override {
    if(!available())
      return false;
    Board board(19, 19);
    BoardHistory history;
    Player nextPlayer = P_BLACK;
    if(!qixiBuildKataGoPositionFromCore(state, rules, board, history, nextPlayer))
      return false;

    MiscNNInputParams inputParams;
    inputParams.drawEquivalentWinsForWhite = searchParams->drawEquivalentWinsForWhite;
    inputParams.conservativePassAndIsRoot = searchParams->conservativePass && isRoot;
    inputParams.enablePassingHacks = searchParams->enablePassingHacks;
    inputParams.nnPolicyTemperature = searchParams->nnPolicyTemperature;
    inputParams.policyOptimism = isRoot ? searchParams->rootPolicyOptimism : searchParams->policyOptimism;
    inputParams.maxHistory = core::kMaxNNHistory;
    nnEval->evaluate(board, history, nextPlayer, inputParams, resultBuf, true, true);
    if(!resultBuf.hasResult || !resultBuf.result)
      return false;
    const NNOutput& nn = *resultBuf.result;

    output = core::LeafPayload{};
    output.winLossWhite = nn.whiteWinProb - nn.whiteLossProb;
    output.noResult = nn.whiteNoResultProb;
    output.scoreMeanWhite = nn.whiteScoreMean;
    output.scoreMeanSqWhite = nn.whiteScoreMeanSq;
    output.leadWhite = nn.whiteLead;
    const double scoreStdev = ScoreValue::getScoreStdev(nn.whiteScoreMean, nn.whiteScoreMeanSq);
    const double staticScoreValue = ScoreValue::expectedWhiteScoreValue(
      nn.whiteScoreMean, scoreStdev, 0.0, 2.0, board.sqrtBoardArea()
    );
    const double dynamicScoreValue = ScoreValue::expectedWhiteScoreValue(
      nn.whiteScoreMean,
      scoreStdev,
      0.0,
      searchParams->dynamicScoreCenterScale,
      board.sqrtBoardArea()
    );
    output.utilityWhite = static_cast<float>(
      output.winLossWhite * searchParams->winLossUtilityFactor +
      output.noResult * searchParams->noResultUtilityForWhite +
      staticScoreValue * searchParams->staticScoreUtilityFactor +
      dynamicScoreValue * searchParams->dynamicScoreUtilityFactor
    );
    output.policy.fill(-1.0f);
    for(core::Move move = 0; move < core::kMoveCount; ++move) {
      const int pos = NNPos::locToPos(qixiCoreMoveLoc(move), 19, nn.nnXLen, nn.nnYLen);
      output.policy[move] = nn.policyProbs[pos];
    }
    if(nn.whiteOwnerMap == nullptr)
      return false;
    for(core::Move move = 0; move < core::kBoardArea; ++move) {
      const core::Point point = core::moveToPoint(move);
      const int pos = NNPos::xyToPos(point.x, point.y, nn.nnXLen);
      output.ownership[move] = nn.whiteOwnerMap[pos];
    }
    output.weight = 1.0f;
    return true;
  }

private:
  NNEvaluator* nnEval = nullptr;
  const SearchParams* searchParams = nullptr;
  NNResultBuf resultBuf;
};

class LinkedNativeKataGoEngine final : public NativeKataGoEngine {
public:
  bool isLinked() const override {
    return true;
  }

  NativeKataGoResult unloadModel() override {
    coreEvaluatorImpl.configure(nullptr, nullptr);
    nnEval.reset();
    loadedEngineID.clear();
    loadedConfig = NativeKataGoModelConfig();
    baseParams = SearchParams();
    return nativeOKResult("Native KataGo model unloaded.");
  }

  NativeKataGoResult loadModel(const NativeKataGoModelConfig& config) override {
    if(config.engineID.empty())
      return nativeInvalidRequestResult("Native KataGo model config is missing engineID.");
    if(config.modelPath.empty())
      return nativeInvalidRequestResult("Native KataGo model config is missing modelPath.");
#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
    // MPSGraph can raise an uncaught Objective-C exception while constructing its
    // Metal device on iOS Simulator. Real Metal-mux inference is a device-only gate.
    return nativeInvalidRequestResult(
      "Metal mux model inference is unavailable in iOS Simulator; use a physical iPhone or iPad."
    );
#endif

    try {
      qixiInitializeKataGoProcessOnce();
      unloadModel();

      kataGoConfig = std::make_unique<ConfigParser>(qixiNativeKataGoConfigMap(config));
      logger = std::make_unique<Logger>(kataGoConfig.get(), false, false);
      logger->setDisabled(true);
      seedRand.init("qixi-native-" + config.engineID);

      Setup::initializeSession(*kataGoConfig);
      baseParams = Setup::loadSingleParams(*kataGoConfig, Setup::SETUP_FOR_ANALYSIS);
      // Single-thread NN path; Qixi search is core::MCTSStore, not KataGo Search.
      const int expectedConcurrentEvals = 1;
      const std::string expectedSha256;
      const int defaultMaxBatchSize = 16;
      const bool defaultRequireExactNNLen = false;
      const bool disableFP16 = false;
      nnEval.reset(Setup::initializeNNEvaluator(
        config.modelPath,
        config.modelPath,
        expectedSha256,
        *kataGoConfig,
        *logger,
        seedRand,
        expectedConcurrentEvals,
        NNPos::MAX_BOARD_LEN,
        NNPos::MAX_BOARD_LEN,
        defaultMaxBatchSize,
        defaultRequireExactNNLen,
        disableFP16,
        Setup::SETUP_FOR_ANALYSIS
      ));

      loadedConfig = config;
      loadedEngineID = config.engineID;
      coreEvaluatorImpl.configure(nnEval.get(), &baseParams);
      return nativeOKResult("Native KataGo model loaded (NN-only; search is core::MCTSStore).");
    }
    catch(const std::exception& ex) {
      unloadModel();
      return nativeInvalidRequestResult(std::string("Native KataGo model load failed: ") + ex.what());
    }
  }

  NativeKataGoResult analyzeRequest(const NativeKataGoAnalysisRequest&) override {
    return nativeInvalidRequestResult(
      "Native in-process analysis uses core::MCTSStore only; "
      "KataGo Search / analyzeRequest is disabled. Use submitCoreRequest / latestCoreSnapshot."
    );
  }

  NativeKataGoResult exportTombstoneToFile(const std::string&) override {
    return nativeInvalidRequestResult(
      "Search tombstones are disabled. Export persistent state via core MCTS "
      "(exportCoreState / core-state.bin)."
    );
  }

  NativeKataGoResult restoreTombstoneFromFile(const std::string&) override {
    return nativeInvalidRequestResult(
      "Search tombstones are disabled. Restore persistent state via core MCTS "
      "(importCoreState / core-state.bin)."
    );
  }

  core::Evaluator* coreEvaluator() override {
    return coreEvaluatorImpl.available() ? &coreEvaluatorImpl : nullptr;
  }

private:
  std::string loadedEngineID;
  NativeKataGoModelConfig loadedConfig;
  SearchParams baseParams;
  Rand seedRand;
  std::unique_ptr<ConfigParser> kataGoConfig;
  std::unique_ptr<Logger> logger;
  std::unique_ptr<NNEvaluator> nnEval;
  LinkedCoreEvaluator coreEvaluatorImpl;
};

#endif

#if !QIXI_ENABLE_NATIVE_KATAGO
class PlaceholderNativeKataGoEngine final : public NativeKataGoEngine {
public:
  bool isLinked() const override {
    return false;
  }

  NativeKataGoResult unloadModel() override {
    return {
      NativeKataGoStatusCode::ok,
      "No native KataGo model is loaded.",
      "",
    };
  }

  NativeKataGoResult loadModel(const NativeKataGoModelConfig&) override {
    return libraryNotLinkedResult();
  }

  NativeKataGoResult analyzeRequest(const NativeKataGoAnalysisRequest&) override {
    return libraryNotLinkedResult();
  }

  NativeKataGoResult exportTombstoneToFile(const std::string&) override {
    return libraryNotLinkedResult();
  }

  NativeKataGoResult restoreTombstoneFromFile(const std::string&) override {
    return libraryNotLinkedResult();
  }

  core::Evaluator* coreEvaluator() override {
    return nullptr;
  }
};
#endif

}  // namespace

std::unique_ptr<NativeKataGoEngine> makeNativeKataGoEngine() {
#if QIXI_ENABLE_NATIVE_KATAGO
  return std::make_unique<LinkedNativeKataGoEngine>();
#else
  return std::make_unique<PlaceholderNativeKataGoEngine>();
#endif
}

}  // namespace qixi
