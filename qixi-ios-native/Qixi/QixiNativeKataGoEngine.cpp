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
#include "search/asyncbot.h"
#include "search/search.h"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstdint>
#include <fcntl.h>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
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

constexpr uint64_t kQixiNativeKataGoMaxPersistentMCTSTombstoneBytes = 256ULL * 1024ULL * 1024ULL;
constexpr size_t kQixiNativeKataGoTombstoneReadChunkBytes = 1024ULL * 1024ULL;

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

std::string qixiReadFileBounded(
  const std::string& path,
  uint64_t maxBytes,
  const std::string& label
) {
  int flags = O_RDONLY;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  int fd = open(path.c_str(), flags);
  if(fd < 0)
    throw IOError("Could not open file for reading: " + path);

  struct stat openedMetadata;
  if(fstat(fd, &openedMetadata) != 0) {
    close(fd);
    throw IOError("Could not inspect opened " + label + ": " + path);
  }
  if(!S_ISREG(openedMetadata.st_mode)) {
    close(fd);
    throw IOError(label + " is not a regular file: " + path);
  }
  if(openedMetadata.st_size < 0) {
    close(fd);
    throw IOError("Could not determine " + label + " byte count: " + path);
  }
  if(static_cast<uint64_t>(openedMetadata.st_size) > maxBytes) {
    close(fd);
    throw IOError(
      label + " exceeds the bounded native tombstone size of " +
      std::to_string(maxBytes) + " bytes: " + path
    );
  }
  const uint64_t openedByteCount = static_cast<uint64_t>(openedMetadata.st_size);

  std::string contents;
  contents.reserve(static_cast<size_t>(openedMetadata.st_size));
  std::vector<char> buffer(kQixiNativeKataGoTombstoneReadChunkBytes);
  while(true) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if(count < 0 && errno == EINTR)
      continue;
    if(count < 0) {
      close(fd);
      throw IOError("Could not read " + label + ": " + path);
    }
    if(count == 0)
      break;
    if(contents.size() + static_cast<size_t>(count) > maxBytes) {
      close(fd);
      throw IOError(
        label + " grew beyond the bounded native tombstone size of " +
        std::to_string(maxBytes) + " bytes while reading: " + path
      );
    }
    contents.append(buffer.data(), static_cast<size_t>(count));
  }
  if(static_cast<uint64_t>(contents.size()) != openedByteCount) {
    close(fd);
    throw IOError(
      label + " opened-byte-count drift while reading: stat=" +
      std::to_string(openedByteCount) + " read=" +
      std::to_string(contents.size()) + " " + path
    );
  }
  if(close(fd) != 0) {
    throw IOError("Could not close " + label + " after reading: " + path);
  }
  return contents;
}

void qixiPrepareInternalTombstoneTempPath(
  const std::string& path,
  const std::string& label
) {
  struct stat metadata;
  if(lstat(path.c_str(), &metadata) != 0) {
    if(errno == ENOENT)
      return;
    throw IOError("Could not inspect " + label + ": " + path);
  }
  if(!S_ISREG(metadata.st_mode))
    throw IOError(label + " is not a regular file: " + path);
  if(std::remove(path.c_str()) != 0)
    throw IOError("Could not remove stale " + label + ": " + path);
}

void qixiCloseAndRemoveTempFile(int fd, const std::string& path) {
  if(fd >= 0)
    close(fd);
  std::remove(path.c_str());
}

void qixiFlushFileDescriptorToStorage(int fd, const std::string& label, const std::string& path) {
#ifdef F_FULLFSYNC
  if(fcntl(fd, F_FULLFSYNC) == 0)
    return;
#endif
  while(fsync(fd) != 0) {
    if(errno == EINTR)
      continue;
    throw IOError("Could not flush " + label + " to storage: " + path);
  }
}

void qixiWriteNewRegularFileExclusively(
  const std::string& path,
  const std::string& contents,
  const std::string& label
) {
  int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
  flags |= O_NOFOLLOW;
#endif
  int fd = open(path.c_str(), flags, 0600);
  if(fd < 0)
    throw IOError("Could not exclusively create " + label + ": " + path);

  size_t offset = 0;
  while(offset < contents.size()) {
    const ssize_t written = write(fd, contents.data() + offset, contents.size() - offset);
    if(written < 0 && errno == EINTR)
      continue;
    if(written <= 0) {
      qixiCloseAndRemoveTempFile(fd, path);
      throw IOError("Could not write " + label + ": " + path);
    }
    offset += static_cast<size_t>(written);
  }

  struct stat openedMetadata;
  if(fstat(fd, &openedMetadata) != 0) {
    qixiCloseAndRemoveTempFile(fd, path);
    throw IOError("Could not inspect opened " + label + " after writing: " + path);
  }
  if(!S_ISREG(openedMetadata.st_mode)) {
    qixiCloseAndRemoveTempFile(fd, path);
    throw IOError(label + " is not a regular file after writing: " + path);
  }
  if(openedMetadata.st_size < 0 ||
     static_cast<uint64_t>(openedMetadata.st_size) != static_cast<uint64_t>(contents.size())) {
    qixiCloseAndRemoveTempFile(fd, path);
    throw IOError(
      label + " byte count drift after writing: stat=" +
      std::to_string(openedMetadata.st_size) + " expected=" +
      std::to_string(contents.size()) + " " + path
    );
  }
  try {
    qixiFlushFileDescriptorToStorage(fd, label, path);
  }
  catch(...) {
    qixiCloseAndRemoveTempFile(fd, path);
    throw;
  }
  if(close(fd) != 0) {
    std::remove(path.c_str());
    throw IOError("Could not close " + label + " after writing: " + path);
  }
}

void qixiRequireAtomicTombstoneTargetPath(
  const std::string& path,
  const std::string& label
) {
  struct stat metadata;
  if(lstat(path.c_str(), &metadata) != 0) {
    if(errno == ENOENT)
      return;
    throw IOError("Could not inspect " + label + ": " + path);
  }
  if(S_ISLNK(metadata.st_mode))
    throw IOError(label + " target must not be a symbolic link: " + path);
  if(S_ISDIR(metadata.st_mode))
    throw IOError(label + " target must not be a directory-shaped artifact: " + path);
  if(!S_ISREG(metadata.st_mode))
    throw IOError(label + " target must be a regular file when replacing: " + path);
}

void qixiWriteFileAtomically(
  const std::string& path,
  const std::string& contents,
  uint64_t maxBytes = kQixiNativeKataGoMaxPersistentMCTSTombstoneBytes
) {
  if(contents.empty())
    throw IOError("Native KataGo atomic-write payload is empty: " + path);
  if(static_cast<uint64_t>(contents.size()) > maxBytes) {
    throw IOError(
      "Native KataGo atomic-write payload exceeds " +
      std::to_string(maxBytes) + " bytes: " + path
    );
  }
  const std::string tmpPath = path + ".tmp";
  qixiRequireAtomicTombstoneTargetPath(path, "Native KataGo atomic-write target path");
  qixiPrepareInternalTombstoneTempPath(tmpPath, "Native KataGo atomic-write temporary path");
  qixiWriteNewRegularFileExclusively(
    tmpPath,
    contents,
    "Native KataGo atomic-write temporary file"
  );
  qixiRequireAtomicTombstoneTargetPath(path, "Native KataGo atomic-write target path");
  if(std::rename(tmpPath.c_str(), path.c_str()) != 0) {
    std::remove(tmpPath.c_str());
    throw IOError("Could not rename tombstone into place: " + path);
  }
}

std::map<std::string, std::string> qixiNativeKataGoConfigMap(const NativeKataGoModelConfig& config) {
  std::map<std::string, std::string> values = {
    {"maxVisits", "64"},
    {"numSearchThreads", "1"},
    {"nnMaxBatchSize", "16"},
    {"nnCacheSizePowerOfTwo", "19"},
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

SearchParams qixiRequestSearchParams(const SearchParams& baseParams, const NativeKataGoAnalysisRequest& request) {
  SearchParams params = baseParams;
  if(request.maxVisits > 0)
    params.maxVisits = request.maxVisits;
  params.wideRootNoise = std::max(0.0, request.rootNoise);
  params.rootNoiseEnabled = request.rootNoise > 0.0;
  params.rootDirichletNoiseWeight = std::max(0.0, std::min(1.0, request.rootNoise));
  return params;
}

nlohmann::json qixiLinkedTombstoneJSON(
  const NativeKataGoModelConfig& config,
  const std::string& rootKeyMaterial,
  const nlohmann::json& persistentMCTS
) {
  nlohmann::json tombstone = nlohmann::json::object();
  tombstone["schemaVersion"] = 2;
  tombstone["kind"] = "qixi-native-katago-tombstone";
  tombstone["engine"] = config.engineID;
  tombstone["resourceName"] = config.resourceName;
  tombstone["modelPath"] = config.modelPath;
  tombstone["coreMLPackagePaths"] = config.coreMLPackagePaths;
  tombstone["minimumMemoryMB"] = config.minimumMemoryMB;
  tombstone["recommendedMemoryMB"] = config.recommendedMemoryMB;
  tombstone["maximumMemoryMB"] = config.maximumMemoryMB;
  tombstone["rootKeyMaterial"] = rootKeyMaterial.empty()
    ? persistentMCTS.value("rootKey", std::string())
    : rootKeyMaterial;
  tombstone["state"] = "native linked persistent mcts";
  tombstone["persistentMCTS"] = persistentMCTS;
  return tombstone;
}

bool qixiLinkedTombstoneMatchesLoadedConfig(
  const nlohmann::json& tombstone,
  const NativeKataGoModelConfig& config
) {
  if(!tombstone.contains("schemaVersion") || !tombstone["schemaVersion"].is_number_integer() ||
     tombstone["schemaVersion"].get<int>() != 2)
    return false;
  if(tombstone.value("kind", std::string()) != "qixi-native-katago-tombstone" ||
     tombstone.value("engine", std::string()) != config.engineID ||
     tombstone.value("resourceName", std::string()) != config.resourceName ||
     tombstone.value("modelPath", std::string()) != config.modelPath ||
     tombstone.value("coreMLPackagePaths", std::vector<std::string>()) != config.coreMLPackagePaths ||
     tombstone.value("minimumMemoryMB", -1) != config.minimumMemoryMB ||
     tombstone.value("recommendedMemoryMB", -1) != config.recommendedMemoryMB ||
     tombstone.value("maximumMemoryMB", -1) != config.maximumMemoryMB)
    return false;
  if(!tombstone.contains("rootKeyMaterial") ||
     !tombstone["rootKeyMaterial"].is_string() ||
     tombstone["rootKeyMaterial"].get<std::string>().empty())
    return false;
  if(!tombstone.contains("persistentMCTS") || !tombstone["persistentMCTS"].is_object())
    return false;
  const nlohmann::json& persistentMCTS = tombstone["persistentMCTS"];
  return persistentMCTS.contains("rootKey") &&
    persistentMCTS["rootKey"].is_string() &&
    !persistentMCTS["rootKey"].get<std::string>().empty() &&
    persistentMCTS.contains("position") &&
    persistentMCTS["position"].is_object();
}

Player qixiToKataGoPlayer(NativeKataGoMoveColor color) {
  return color == NativeKataGoMoveColor::black ? P_BLACK : P_WHITE;
}

int qixiToKataGoKoRule(NativeKataGoKoRule rule) {
  switch(rule) {
  case NativeKataGoKoRule::simple:
    return Rules::KO_SIMPLE;
  case NativeKataGoKoRule::positional:
    return Rules::KO_POSITIONAL;
  case NativeKataGoKoRule::situational:
    return Rules::KO_SITUATIONAL;
  case NativeKataGoKoRule::spight:
    return Rules::KO_SPIGHT;
  }
  return Rules::KO_SIMPLE;
}

int qixiToKataGoScoringRule(NativeKataGoScoringRule rule) {
  return rule == NativeKataGoScoringRule::area ? Rules::SCORING_AREA : Rules::SCORING_TERRITORY;
}

int qixiToKataGoTaxRule(NativeKataGoTaxRule rule) {
  switch(rule) {
  case NativeKataGoTaxRule::none:
    return Rules::TAX_NONE;
  case NativeKataGoTaxRule::seki:
    return Rules::TAX_SEKI;
  case NativeKataGoTaxRule::all:
    return Rules::TAX_ALL;
  }
  return Rules::TAX_NONE;
}

int qixiToKataGoWhiteHandicapBonusRule(NativeKataGoWhiteHandicapBonusRule rule) {
  switch(rule) {
  case NativeKataGoWhiteHandicapBonusRule::zero:
    return Rules::WHB_ZERO;
  case NativeKataGoWhiteHandicapBonusRule::n:
    return Rules::WHB_N;
  case NativeKataGoWhiteHandicapBonusRule::nMinusOne:
    return Rules::WHB_N_MINUS_ONE;
  }
  return Rules::WHB_N;
}

Rules qixiToKataGoRules(const NativeKataGoRules& qixiRules, double komi) {
  return Rules(
    qixiToKataGoKoRule(qixiRules.koRule),
    qixiToKataGoScoringRule(qixiRules.scoringRule),
    qixiToKataGoTaxRule(qixiRules.taxRule),
    qixiRules.multiStoneSuicideLegal,
    qixiRules.hasButton,
    qixiToKataGoWhiteHandicapBonusRule(qixiRules.whiteHandicapBonusRule),
    qixiRules.friendlyPassOk,
    static_cast<float>(komi)
  );
}

Loc qixiToKataGoLoc(const NativeKataGoMove& move) {
  return move.pass ? Board::PASS_LOC : Location::getLoc(move.x, move.y, 19);
}

int qixiClampVisitCount(int64_t visits) {
  if(visits <= 0)
    return 0;
  if(visits > std::numeric_limits<int>::max())
    return std::numeric_limits<int>::max();
  return static_cast<int>(visits);
}

struct QixiKataGoRoot {
  Board board;
  BoardHistory history;
  Player nextPlayer;
  Rules rules;
};

bool qixiBuildKataGoRoot(const NativeKataGoAnalysisRequest& request, QixiKataGoRoot& root) {
  Board board(19, 19);
  std::vector<Move> placements;
  placements.reserve(request.initialBoard.size());
  for(size_t index = 0; index < request.initialBoard.size(); ++index) {
    const NativeKataGoBoardPoint point = request.initialBoard[index];
    if(point == NativeKataGoBoardPoint::empty)
      continue;
    const int x = static_cast<int>(index % 19);
    const int y = static_cast<int>(index / 19);
    const Player stonePlayer = point == NativeKataGoBoardPoint::black ? P_BLACK : P_WHITE;
    placements.emplace_back(Location::getLoc(x, y, 19), stonePlayer);
  }
  if(!placements.empty() && !board.setStonesFailIfNoLibs(placements))
    return false;
  Rules rules = qixiToKataGoRules(request.rules, request.komi);
  Player initialPlayer = request.moves.empty()
    ? qixiToKataGoPlayer(request.nextPlayer)
    : qixiToKataGoPlayer(request.moves.front().color);
  BoardHistory history(board, initialPlayer, rules, 0);
  history.setAssumeMultipleStartingBlackMovesAreHandicap(false);

  for(const NativeKataGoMove& move: request.moves) {
    Player movePlayer = qixiToKataGoPlayer(move.color);
    Loc moveLoc = qixiToKataGoLoc(move);
    if(!history.makeBoardMoveTolerant(board, moveLoc, movePlayer, false))
      return false;
  }

  root.board = board;
  root.history = history;
  root.nextPlayer = qixiToKataGoPlayer(request.nextPlayer);
  root.rules = rules;
  return root.history.moveHistory.size() == request.moves.size();
}

nlohmann::json qixiMoveInfoToResponseMoveJSON(
  const nlohmann::json& moveInfo,
  const nlohmann::json& rootInfo,
  const Board& board
) {
  const std::string moveText = moveInfo.value("move", std::string());
  Loc loc = Board::NULL_LOC;
  if(moveText.empty() || !Location::tryOfString(moveText, board.x_size, board.y_size, loc) ||
     loc == Board::PASS_LOC || loc == Board::NULL_LOC)
    return nlohmann::json();

  nlohmann::json move = nlohmann::json::object();
  move["x"] = Location::getX(loc, board.x_size);
  move["y"] = Location::getY(loc, board.x_size);
  move["move"] = moveText;
  move["visits"] = qixiClampVisitCount(moveInfo.value("visits", int64_t{0}));
  move["winrate"] = moveInfo.value("winrate", 0.0);
  move["scoreMean"] = moveInfo.value(
    "scoreMean",
    moveInfo.value("scoreLead", rootInfo.value("scoreMean", 0.0))
  );
  return move;
}

nlohmann::json qixiMCTSTreeOwnershipJSON(Search& search) {
  nlohmann::json ownership = nlohmann::json::array();
  const std::vector<double> averageOwnership = search.getAverageTreeOwnership();
  for(double value: averageOwnership)
    ownership.push_back(value);
  return ownership;
}

std::string qixiBuildAnalysisResponseJSON(
  const std::string& engineID,
  const NativeKataGoAnalysisRequest& request,
  Search& search,
  const QixiKataGoRoot& root
) {
  nlohmann::json kataGoResponse = nlohmann::json::object();
  (void)search.getAnalysisJson(
    root.nextPlayer,
    16,
    false,
    false,
    true,
    false,
    false,
    false,
    false,
    false,
    kataGoResponse
  );

  const nlohmann::json rootInfo =
    kataGoResponse.contains("rootInfo") && kataGoResponse["rootInfo"].is_object()
      ? kataGoResponse["rootInfo"]
      : nlohmann::json::object();
  const nlohmann::json moveInfos =
    kataGoResponse.contains("moveInfos") && kataGoResponse["moveInfos"].is_array()
      ? kataGoResponse["moveInfos"]
      : nlohmann::json::array();

  nlohmann::json moves = nlohmann::json::array();
  const size_t moveCount = std::min<size_t>(80, moveInfos.size());
  for(size_t index = 0; index < moveCount; ++index) {
    nlohmann::json move = qixiMoveInfoToResponseMoveJSON(moveInfos[index], rootInfo, root.board);
    if(!move.is_null())
      moves.push_back(move);
  }

  nlohmann::json response = nlohmann::json::object();
  response["engine"] = engineID;
  response["state"] = "running native in-process analysis";
  response["positionKey"] = "native-inprocess:" + nativeKataGoPositionKeyMaterial(request);
  response["winrate"] = rootInfo.value("winrate", kataGoResponse.value("rootWinrate", 0.0));
  response["scoreMean"] = rootInfo.value("scoreMean", kataGoResponse.value("scoreMean", 0.0));
  response["visits"] = qixiClampVisitCount(rootInfo.value("visits", static_cast<int64_t>(request.maxVisits)));
  response["moves"] = moves;
  response["ownership"] = qixiMCTSTreeOwnershipJSON(search);
  return response.dump();
}

[[maybe_unused]] void qixiProbeSearchAPIs(Search& search, const NativeKataGoAnalysisRequest& request, const QixiKataGoRoot& root) {
  search.setPersistentMCTSEnabled(true);
  search.setPositionForMCTSPersistence(root.nextPlayer, root.board, root.history);
  search.setPosition(root.nextPlayer, root.board, root.history);

  std::vector<AnalysisData> analysis;
  search.getAnalysisData(analysis, 10, false, 16, false);

  std::vector<double> ownership = search.getAverageTreeOwnership();
  std::pair<std::vector<double>, std::vector<double>> ownershipAndDeviation =
    search.getAverageAndStandardDeviationTreeOwnership();
  (void)ownership;
  (void)ownershipAndDeviation;

  const std::string responseJSON = qixiBuildAnalysisResponseJSON("b6", request, search, root);
  (void)responseJSON;
}

[[maybe_unused]] void qixiProbeAsyncBotAPIs(
  AsyncBot& bot,
  const NativeKataGoAnalysisRequest& request,
  const QixiKataGoRoot& root,
  const SearchParams& params
) {
  bot.setPosition(root.nextPlayer, root.board, root.history);
  bot.setAlwaysIncludeOwnerMap(true);
  bot.setParams(params);
  Search* search = bot.getSearchStopAndWait();
  qixiProbeSearchAPIs(*search, request, root);
  (void)bot.genMoveSynchronousAnalyze(
    root.nextPlayer,
    TimeControls(),
    1.0,
    0.0,
    0.0,
    [](const Search*) {}
  );
}

class LinkedNativeKataGoEngine final : public NativeKataGoEngine {
public:
  bool isLinked() const override {
    return true;
  }

  NativeKataGoResult unloadModel() override {
    bot.reset();
    nnEval.reset();
    loadedEngineID.clear();
    loadedConfig = NativeKataGoModelConfig();
    lastRootKeyMaterial.clear();
    baseParams = SearchParams();
    return nativeOKResult("Native KataGo model unloaded.");
  }

  NativeKataGoResult loadModel(const NativeKataGoModelConfig& config) override {
    if(config.engineID.empty())
      return nativeInvalidRequestResult("Native KataGo model config is missing engineID.");
    if(config.modelPath.empty())
      return nativeInvalidRequestResult("Native KataGo model config is missing modelPath.");

    try {
      qixiInitializeKataGoProcessOnce();
      unloadModel();

      kataGoConfig = std::make_unique<ConfigParser>(qixiNativeKataGoConfigMap(config));
      logger = std::make_unique<Logger>(kataGoConfig.get(), false, false);
      logger->setDisabled(true);
      seedRand.init("qixi-native-" + config.engineID);

      Setup::initializeSession(*kataGoConfig);
      baseParams = Setup::loadSingleParams(*kataGoConfig, Setup::SETUP_FOR_ANALYSIS);
      const int expectedConcurrentEvals = std::max(1, baseParams.numThreads);
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

      bot = std::make_unique<AsyncBot>(baseParams, nnEval.get(), logger.get(), "qixi-native-search-" + config.engineID);
      bot->setAlwaysIncludeOwnerMap(true);
      Search* search = bot->getSearchStopAndWait();
      search->setPersistentMCTSEnabled(true);
      search->setAlwaysIncludeOwnerMap(true);
      loadedConfig = config;
      loadedEngineID = config.engineID;
      lastRootKeyMaterial.clear();
      return nativeOKResult("Native KataGo model loaded.");
    }
    catch(const std::exception& ex) {
      unloadModel();
      return nativeInvalidRequestResult(std::string("Native KataGo model load failed: ") + ex.what());
    }
  }

  NativeKataGoResult analyzeRequest(const NativeKataGoAnalysisRequest& request) override {
    if(!bot || !nnEval)
      return nativeInvalidRequestResult("No native KataGo model is loaded.");

    QixiKataGoRoot root;
    if(!qixiBuildKataGoRoot(request, root))
      return nativeInvalidRequestResult("Native KataGo request could not be replayed into a legal KataGo root.");

    try {
      SearchParams params = qixiRequestSearchParams(baseParams, request);
      Search* search = bot->getSearchStopAndWait();
      search->setParams(params);
      search->setAlwaysIncludeOwnerMap(true);
      search->setPersistentMCTSEnabled(true);
      search->setPositionForMCTSPersistence(root.nextPlayer, root.board, root.history);
      search->runWholeSearch(root.nextPlayer);
      lastRootKeyMaterial = nativeKataGoPositionKeyMaterial(request);
      return nativeOKResult(
        "Native KataGo analysis complete.",
        qixiBuildAnalysisResponseJSON(loadedEngineID, request, *search, root)
      );
    }
    catch(const std::exception& ex) {
      return nativeInvalidRequestResult(std::string("Native KataGo analysis failed: ") + ex.what());
    }
  }

  NativeKataGoResult exportTombstoneToFile(const std::string& filePath) override {
    if(!bot || !nnEval || loadedEngineID.empty())
      return nativeInvalidRequestResult("No native KataGo model is loaded.");
    const std::string rawPath = filePath + ".persistent-mcts.tmp";
    try {
      qixiPrepareInternalTombstoneTempPath(rawPath, "Native KataGo raw persistent-MCTS export temporary path");
      Search* search = bot->getSearchStopAndWait();
      search->setPersistentMCTSEnabled(true);
      search->exportPersistentMCTS(rawPath);
      nlohmann::json persistentMCTS = nlohmann::json::parse(qixiReadFileBounded(
        rawPath,
        kQixiNativeKataGoMaxPersistentMCTSTombstoneBytes,
        "Native KataGo exported persistent MCTS"
      ));
      std::remove(rawPath.c_str());
      const nlohmann::json tombstone = qixiLinkedTombstoneJSON(
        loadedConfig,
        lastRootKeyMaterial,
        persistentMCTS
      );
      qixiWriteFileAtomically(filePath, tombstone.dump(2) + "\n");
      search->clearSearch();
      search->setPersistentMCTSEnabled(true);
      return nativeOKResult("Native KataGo persistent MCTS tombstone exported.");
    }
    catch(const std::exception& ex) {
      std::remove(rawPath.c_str());
      return nativeInvalidRequestResult(std::string("Native KataGo tombstone export failed: ") + ex.what());
    }
  }

  NativeKataGoResult restoreTombstoneFromFile(const std::string& filePath) override {
    if(!bot || !nnEval || loadedEngineID.empty())
      return nativeInvalidRequestResult("No native KataGo model is loaded.");
    const std::string rawPath = filePath + ".persistent-mcts.restore.tmp";
    try {
      qixiPrepareInternalTombstoneTempPath(rawPath, "Native KataGo raw persistent-MCTS restore temporary path");
      const nlohmann::json tombstone = nlohmann::json::parse(qixiReadFileBounded(
        filePath,
        kQixiNativeKataGoMaxPersistentMCTSTombstoneBytes,
        "Native KataGo persistent MCTS tombstone"
      ));
      if(!qixiLinkedTombstoneMatchesLoadedConfig(tombstone, loadedConfig))
        return nativeInvalidRequestResult("Native KataGo tombstone does not match the loaded engine and model config.");
      qixiWriteFileAtomically(rawPath, tombstone["persistentMCTS"].dump(2) + "\n");
      Search* search = bot->getSearchStopAndWait();
      search->restorePersistentMCTSTombstone(rawPath);
      search->setAlwaysIncludeOwnerMap(true);
      lastRootKeyMaterial = tombstone.value("rootKeyMaterial", std::string());
      std::remove(rawPath.c_str());
      return nativeOKResult("Native KataGo persistent MCTS tombstone restored.");
    }
    catch(const std::exception& ex) {
      std::remove(rawPath.c_str());
      return nativeInvalidRequestResult(std::string("Native KataGo tombstone restore failed: ") + ex.what());
    }
  }

private:
  std::string loadedEngineID;
  NativeKataGoModelConfig loadedConfig;
  std::string lastRootKeyMaterial;
  SearchParams baseParams;
  Rand seedRand;
  std::unique_ptr<ConfigParser> kataGoConfig;
  std::unique_ptr<Logger> logger;
  std::unique_ptr<NNEvaluator> nnEval;
  std::unique_ptr<AsyncBot> bot;
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
