#include "host_nn_bridge.hpp"

#include "core/global.h"
#include "game/boardhistory.h"
#include "search/searchparams.h"

#include <cmath>
#include <mutex>
#include <sstream>

namespace qixi::oracle {
namespace {

constexpr int kBoardLen = 19;

Player qixiColorToPlayer(core::Color c) {
  if(c == core::Color::black)
    return P_BLACK;
  if(c == core::Color::white)
    return P_WHITE;
  return C_EMPTY;
}

Loc qixiMoveToLoc(core::Move move) {
  if(move == core::kMovePass)
    return Board::PASS_LOC;
  if(move >= core::kBoardArea)
    return Board::NULL_LOC;
  const core::Point p = core::moveToPoint(move);
  return Location::getLoc(p.x, p.y, kBoardLen);
}

core::Move locToQixiMove(Loc loc) {
  if(loc == Board::PASS_LOC)
    return core::kMovePass;
  if(loc == Board::NULL_LOC)
    return core::kMovePass;
  const int x = Location::getX(loc, kBoardLen);
  const int y = Location::getY(loc, kBoardLen);
  return core::pointToMove(x, y);
}

Rules qixiRulesToKataGo(const core::Rules& rules) {
  Rules out = Rules::getTrompTaylorish();
  out.komi = rules.komi;
  switch(rules.koRule) {
    case core::KoRule::simple: out.koRule = Rules::KO_SIMPLE; break;
    case core::KoRule::positional: out.koRule = Rules::KO_POSITIONAL; break;
    case core::KoRule::situational: out.koRule = Rules::KO_SITUATIONAL; break;
  }
  switch(rules.scoringRule) {
    case core::ScoringRule::area: out.scoringRule = Rules::SCORING_AREA; break;
    case core::ScoringRule::territory: out.scoringRule = Rules::SCORING_TERRITORY; break;
  }
  out.multiStoneSuicideLegal = rules.multiStoneSuicideLegal;
  return out;
}

std::string minimalAnalysisConfigText() {
  // Minimal config for host Eigen analysis: 1 search thread, no wide root noise.
  return R"CFG(
logToStderr = false
logToStdout = false
logAllRequests = false
logAllResponses = false
logSearchInfo = false
nnMaxBatchSize = 1
nnCacheSizePowerOfTwo = 16
nnMutexPoolSizePowerOfTwo = 10
numSearchThreads = 1
minPlayoutsPerThread = 0
maxVisits = 1
maxPlayouts = 1
maxTime = 1e20
chosenMoveTemperature = 0.0
chosenMoveTemperatureEarly = 0.0
rootNoiseEnabled = false
wideRootNoise = 0.0
useLcbForSelection = false
cpuctExploration = 1.1
cpuctExplorationLog = 0.0
fpuReductionMax = 0.0
rootFpuReductionMax = 0.0
winLossUtilityFactor = 1.0
staticScoreUtilityFactor = 0.0
dynamicScoreUtilityFactor = 0.0
noResultUtilityForWhite = 0.0
drawEquivalentWinsForWhite = 0.5
nnPolicyTemperature = 1.0
rootPolicyOptimism = 0.0
policyOptimism = 0.0
conservativePass = false
enablePassingHacks = false
useGraphSearch = false
useUncertainty = false
useNoisePruning = false
)CFG";
}

} // namespace

void initKataGoProcessOnce() {
  static std::once_flag once;
  std::call_once(once, []() {
    Board::initHash();
    ScoreValue::initTables();
  });
}

std::unique_ptr<HostNNContext> createHostNNContext(
  const std::string& modelPath,
  std::string* error
) {
  try {
    initKataGoProcessOnce();
    auto ctx = std::make_unique<HostNNContext>();
    ctx->modelPath = modelPath;
    ctx->cfg = std::make_unique<ConfigParser>();
    {
      std::istringstream in(minimalAnalysisConfigText());
      ctx->cfg->initialize(in);
    }
    ctx->logger = std::make_unique<Logger>(ctx->cfg.get(), false, false);
    ctx->logger->setDisabled(true);
    ctx->seedRand.init("qixi-oracle-seed");

    Setup::initializeSession(*ctx->cfg);
    ctx->baseParams = Setup::loadSingleParams(*ctx->cfg, Setup::SETUP_FOR_ANALYSIS);
    ctx->baseParams.numThreads = 1;
    ctx->baseParams.maxVisits = 1;
    ctx->baseParams.maxPlayouts = 1;
    ctx->baseParams.rootNoiseEnabled = false;
    ctx->baseParams.wideRootNoise = 0.0;
    ctx->baseParams.chosenMoveTemperature = 0.0;
    ctx->baseParams.chosenMoveTemperatureEarly = 0.0;
    ctx->baseParams.useLcbForSelection = false;

    const int expectedConcurrentEvals = 1;
    const std::string expectedSha256;
    const int defaultMaxBatchSize = 1;
    const bool defaultRequireExactNNLen = false;
    const bool disableFP16 = true;
    ctx->nnEval.reset(Setup::initializeNNEvaluator(
      modelPath,
      modelPath,
      expectedSha256,
      *ctx->cfg,
      *ctx->logger,
      ctx->seedRand,
      expectedConcurrentEvals,
      NNPos::MAX_BOARD_LEN,
      NNPos::MAX_BOARD_LEN,
      defaultMaxBatchSize,
      defaultRequireExactNNLen,
      disableFP16,
      Setup::SETUP_FOR_ANALYSIS
    ));
    return ctx;
  }
  catch(const std::exception& ex) {
    if(error)
      *error = std::string("createHostNNContext failed: ") + ex.what();
    return nullptr;
  }
}

bool buildKataGoPosition(
  const core::BoardState& state,
  const core::Rules& rules,
  Board& board,
  BoardHistory& history,
  Player& nextPlayer,
  std::string* error
) {
  try {
    board = Board(kBoardLen, kBoardLen);
    const Rules kataRules = qixiRulesToKataGo(rules);
    history = BoardHistory(board, P_BLACK, kataRules, 0);
    nextPlayer = P_BLACK;

    // Replay ordered move history so ko/superko and lineage match.
    for(const core::MoveRecord& rec : state.moves) {
      const Loc loc = qixiMoveToLoc(rec.move);
      const Player pla = qixiColorToPlayer(rec.pla);
      if(pla != nextPlayer) {
        if(error) *error = "history side-to-move mismatch during replay";
        return false;
      }
      if(!history.isLegal(board, loc, pla)) {
        if(error) *error = "illegal move during history replay";
        return false;
      }
      history.makeBoardMoveAssumeLegal(board, loc, pla, nullptr);
      nextPlayer = getOpp(pla);
    }

    // Verify visible stones match.
    for(int y = 0; y < kBoardLen; ++y) {
      for(int x = 0; x < kBoardLen; ++x) {
        const core::Color expected = state.cells[core::pointToMove(x, y)];
        const Color actual = board.colors[Location::getLoc(x, y, kBoardLen)];
        const Color want =
          expected == core::Color::black ? C_BLACK :
          expected == core::Color::white ? C_WHITE : C_EMPTY;
        if(actual != want) {
          if(error) *error = "stone mismatch after history replay";
          return false;
        }
      }
    }
    if(qixiColorToPlayer(state.nextPla) != nextPlayer) {
      if(error) *error = "next player mismatch after history replay";
      return false;
    }
    return true;
  }
  catch(const std::exception& ex) {
    if(error) *error = std::string("buildKataGoPosition: ") + ex.what();
    return false;
  }
}

HostCoreEvaluator::HostCoreEvaluator(HostNNContext* ctx) : ctx_(ctx) {}

bool HostCoreEvaluator::evaluate(
  const core::BoardState& state,
  const core::Rules& rules,
  bool isRoot,
  core::LeafPayload& output
) {
  if(ctx_ == nullptr || ctx_->nnEval == nullptr)
    return false;
  Board board;
  BoardHistory history;
  Player nextPlayer = P_BLACK;
  std::string err;
  if(!buildKataGoPosition(state, rules, board, history, nextPlayer, &err))
    return false;

  MiscNNInputParams inputParams;
  inputParams.drawEquivalentWinsForWhite = ctx_->baseParams.drawEquivalentWinsForWhite;
  inputParams.conservativePassAndIsRoot = ctx_->baseParams.conservativePass && isRoot;
  inputParams.enablePassingHacks = ctx_->baseParams.enablePassingHacks;
  inputParams.nnPolicyTemperature = ctx_->baseParams.nnPolicyTemperature;
  inputParams.policyOptimism = isRoot ? ctx_->baseParams.rootPolicyOptimism : ctx_->baseParams.policyOptimism;
  inputParams.maxHistory = core::kMaxNNHistory;

  ctx_->nnEval->evaluate(board, history, nextPlayer, inputParams, resultBuf_, /*skipCache*/true, /*includeOwnerMap*/true);
  if(!resultBuf_.hasResult || !resultBuf_.result)
    return false;
  const NNOutput& nn = *resultBuf_.result;

  output = core::LeafPayload{};
  output.winLossWhite = nn.whiteWinProb - nn.whiteLossProb;
  output.noResult = nn.whiteNoResultProb;
  output.scoreMeanWhite = nn.whiteScoreMean;
  output.scoreMeanSqWhite = nn.whiteScoreMeanSq;
  output.leadWhite = nn.whiteLead;
  output.utilityWhite = static_cast<float>(
    output.winLossWhite * ctx_->baseParams.winLossUtilityFactor
  );
  output.policy.fill(-1.0f);
  for(core::Move move = 0; move < core::kMoveCount; ++move) {
    const Loc loc = qixiMoveToLoc(move);
    const int pos = NNPos::locToPos(loc, kBoardLen, nn.nnXLen, nn.nnYLen);
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

// Silence unused warning if locToQixiMove not used in this TU.
[[maybe_unused]] static core::Move keepLocToQixiMoveLinked(Loc loc) {
  return locToQixiMove(loc);
}

} // namespace qixi::oracle
