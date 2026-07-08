#include "QixiNativeKataGoCore.hpp"

#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace {

constexpr off_t kOversizedNativeTombstoneBytes = 256LL * 1024LL * 1024LL + 1LL;

void expect(bool condition, const std::string& message) {
  if(!condition) {
    std::cerr << "Native KataGo core smoke failed: " << message << std::endl;
    std::exit(1);
  }
}

qixi::NativeKataGoModelConfig b6Config() {
  qixi::NativeKataGoModelConfig config;
  config.engineID = "b6";
  config.resourceName = "g170-b6c96-s175395328-d26788732.bin.gz";
  config.modelPath = "/tmp/g170-b6c96-s175395328-d26788732.bin.gz";
  config.minimumMemoryMB = 256;
  config.recommendedMemoryMB = 512;
  config.maximumMemoryMB = 768;
  return config;
}

qixi::NativeKataGoModelConfig b18Config() {
  qixi::NativeKataGoModelConfig config;
  config.engineID = "b18nbt";
  config.resourceName = "b18nbt.bin";
  config.modelPath = "/tmp/b18nbt.bin";
  config.minimumMemoryMB = 1024;
  config.recommendedMemoryMB = 1536;
  config.maximumMemoryMB = 2048;
  return config;
}

std::string tempPath(const std::string& filename) {
  const char* tmpDir = std::getenv("TMPDIR");
  const std::string root = tmpDir == nullptr || std::string(tmpDir).empty() ? "/tmp" : tmpDir;
  if(root.back() == '/')
    return root + filename;
  return root + "/" + filename;
}

std::string readFile(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void writeFile(const std::string& path, const std::string& contents) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  out << contents;
}

void writeSparseFile(const std::string& path, off_t byteCount) {
  std::remove(path.c_str());
  {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << "x";
  }
  expect(truncate(path.c_str(), byteCount) == 0, "test fixture creates sparse oversized file");
}

std::string extractPositionKey(const std::string& responseJSON) {
  const std::string prefix = R"("positionKey":")";
  const size_t start = responseJSON.find(prefix);
  if(start == std::string::npos)
    return "";
  const size_t valueStart = start + prefix.size();
  const size_t valueEnd = responseJSON.find('"', valueStart);
  if(valueEnd == std::string::npos)
    return "";
  return responseJSON.substr(valueStart, valueEnd - valueStart);
}

size_t boardIndex(int x, int y) {
  return static_cast<size_t>(y * 19 + x);
}

int countBoardPoints(
  const qixi::NativeKataGoAnalysisRequest& request,
  qixi::NativeKataGoBoardPoint point
) {
  int count = 0;
  for(qixi::NativeKataGoBoardPoint value : request.finalBoard) {
    if(value == point)
      count += 1;
  }
  return count;
}

int countInitialBoardPoints(
  const qixi::NativeKataGoAnalysisRequest& request,
  qixi::NativeKataGoBoardPoint point
) {
  int count = 0;
  for(qixi::NativeKataGoBoardPoint value : request.initialBoard) {
    if(value == point)
      count += 1;
  }
  return count;
}

bool hasChineseRules(const qixi::NativeKataGoRules& rules) {
  return rules.koRule == qixi::NativeKataGoKoRule::simple &&
    rules.scoringRule == qixi::NativeKataGoScoringRule::area &&
    rules.taxRule == qixi::NativeKataGoTaxRule::none &&
    !rules.multiStoneSuicideLegal &&
    !rules.hasButton &&
    rules.whiteHandicapBonusRule == qixi::NativeKataGoWhiteHandicapBonusRule::n &&
    rules.friendlyPassOk;
}

std::string emptyAnalysisRequestJSON() {
  return R"({"moves":[],"maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string emptyExplicitChineseRulesRequestJSON() {
  return R"({"moves":[],"rules":"Chinese","maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string emptyUnsupportedRulesRequestJSON() {
  return R"({"moves":[],"rules":"Japanese","maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string mixedAnalysisRequestJSON() {
  return R"({"moves":[{"color":"B","x":3,"y":3},{"color":"W","pass":true}],"maxVisits":64,"komi":7.5,"rootNoise":0.0})";
}

std::string setupStonesRequestJSON() {
  return R"({"setupStones":[{"color":"B","x":3,"y":3},{"color":"W","x":15,"y":15}],"moves":[],"nextPlayer":"W","maxVisits":64,"komi":7.5,"rootNoise":0.0})";
}

std::string duplicateSetupStonesRequestJSON() {
  return R"({"setupStones":[{"color":"B","x":3,"y":3},{"color":"W","x":3,"y":3}],"moves":[],"nextPlayer":"B","maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string sameStonesHistoryARequestJSON(int maxVisits = 1) {
  return "{\"moves\":["
    "{\"color\":\"B\",\"x\":3,\"y\":3},"
    "{\"color\":\"W\",\"x\":15,\"y\":15},"
    "{\"color\":\"B\",\"x\":16,\"y\":3},"
    "{\"color\":\"W\",\"x\":2,\"y\":15}"
    "],\"maxVisits\":" + std::to_string(maxVisits) + ",\"komi\":7.5,\"rootNoise\":0.0}";
}

std::string sameStonesHistoryAReorderedRequestJSON() {
  return R"({
    "rootNoise": 0.00,
    "komi": 7.500,
    "maxVisits": 128,
    "moves": [
      {"y": 3, "x": 3, "color": "B"},
      {"x": 15, "color": "W", "y": 15},
      {"color": "B", "y": 3, "x": 16},
      {"y": 15, "color": "W", "x": 2}
    ]
  })";
}

std::string sameStonesHistoryBRequestJSON() {
  return R"({"moves":[{"color":"B","x":16,"y":3},{"color":"W","x":2,"y":15},{"color":"B","x":3,"y":3},{"color":"W","x":15,"y":15}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string singlePassRequestJSON() {
  return R"({"moves":[{"color":"B","pass":true}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string legalRepeatedCoordinateAfterCaptureRequestJSON() {
  return R"({"moves":[{"color":"W","x":1,"y":1},{"color":"B","x":0,"y":1},{"color":"B","x":1,"y":0},{"color":"B","x":2,"y":1},{"color":"B","x":1,"y":2},{"color":"B","x":1,"y":1}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string occupiedPointIllegalRequestJSON() {
  return R"({"moves":[{"color":"B","x":3,"y":3},{"color":"W","x":3,"y":3}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string suicideIllegalRequestJSON() {
  return R"({"moves":[{"color":"B","x":0,"y":1},{"color":"B","x":1,"y":0},{"color":"W","x":0,"y":0}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string simpleKoIllegalRequestJSON() {
  return R"({"moves":[{"color":"B","x":0,"y":0},{"color":"B","x":1,"y":0},{"color":"B","x":2,"y":0},{"color":"B","x":3,"y":0},{"color":"B","x":4,"y":1},{"color":"W","x":3,"y":1},{"color":"W","x":4,"y":2},{"color":"W","x":4,"y":0},{"color":"B","x":4,"y":1}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})";
}

std::string emptyWithRootNoiseRequestJSON() {
  return R"({"moves":[],"maxVisits":1,"komi":7.5,"rootNoise":0.04})";
}

std::string emptyWithDifferentKomiRequestJSON() {
  return R"({"moves":[],"maxVisits":1,"komi":6.5,"rootNoise":0.0})";
}

std::string fullOwnershipJSON(const std::string& value = "0.0") {
  std::string out = "[";
  for(int index = 0; index < 19 * 19; ++index) {
    if(index > 0)
      out += ",";
    out += value;
  }
  out += "]";
  return out;
}

std::string fakeAnalysisResponseJSON(
  const std::string& winrate = "0.52",
  const std::string& movesJSON = "[]",
  const std::string& ownershipJSON = fullOwnershipJSON(),
  const std::string& engine = "b6"
) {
  return "{\"engine\":\"" + engine + "\","
    "\"state\":\"fake native analysis\","
    "\"positionKey\":\"fake\","
    "\"winrate\":" + winrate + ","
    "\"scoreMean\":1.25,"
    "\"visits\":1,"
    "\"moves\":" + movesJSON + ","
    "\"ownership\":" + ownershipJSON + "}";
}

class FakeNativeKataGoEngine final : public qixi::NativeKataGoEngine {
public:
  bool linked = true;
  int unloadModelCalls = 0;
  int loadModelCalls = 0;
  int analyzeCalls = 0;
  int exportTombstoneCalls = 0;
  int restoreTombstoneCalls = 0;
  std::string engineIDToFailOnLoad;
  bool failUnloadModel = false;
  bool skipExportTombstoneWrite = false;
  bool writeEmptyTombstone = false;
  bool writeOversizedTombstone = false;
  bool failRestoreTombstone = false;
  qixi::NativeKataGoModelConfig loadedConfig;
  qixi::NativeKataGoAnalysisRequest lastRequest;
  std::string lastExportTombstonePath;
  std::string lastRestoreTombstonePath;
  std::string responseJSON = fakeAnalysisResponseJSON();

  bool isLinked() const override {
    return linked;
  }

  qixi::NativeKataGoResult unloadModel() override {
    unloadModelCalls += 1;
    if(failUnloadModel) {
      return {
        qixi::NativeKataGoStatusCode::invalidRequest,
        "fake native model unload failed",
        "",
      };
    }
    loadedConfig = {};
    return {qixi::NativeKataGoStatusCode::ok, "fake native model unloaded", ""};
  }

  qixi::NativeKataGoResult loadModel(const qixi::NativeKataGoModelConfig& config) override {
    loadModelCalls += 1;
    if(config.engineID == engineIDToFailOnLoad) {
      return {
        qixi::NativeKataGoStatusCode::invalidRequest,
        "fake native model load failed",
        "",
      };
    }
    loadedConfig = config;
    return {qixi::NativeKataGoStatusCode::ok, "fake native model loaded", ""};
  }

  qixi::NativeKataGoResult analyzeRequest(const qixi::NativeKataGoAnalysisRequest& request) override {
    analyzeCalls += 1;
    lastRequest = request;
    return {
      qixi::NativeKataGoStatusCode::ok,
      "fake native analysis",
      responseJSON,
    };
  }

  qixi::NativeKataGoResult exportTombstoneToFile(const std::string& filePath) override {
    exportTombstoneCalls += 1;
    lastExportTombstonePath = filePath;
    if(writeOversizedTombstone) {
      writeSparseFile(filePath, kOversizedNativeTombstoneBytes);
    } else if(!skipExportTombstoneWrite) {
      std::ofstream out(filePath, std::ios::binary | std::ios::trunc);
      if(!writeEmptyTombstone)
        out << "fake-native-tombstone";
    }
    return {qixi::NativeKataGoStatusCode::ok, "fake tombstone exported", ""};
  }

  qixi::NativeKataGoResult restoreTombstoneFromFile(const std::string& filePath) override {
    restoreTombstoneCalls += 1;
    lastRestoreTombstonePath = filePath;
    if(failRestoreTombstone) {
      return {
        qixi::NativeKataGoStatusCode::invalidRequest,
        "fake tombstone restore failed",
        "",
      };
    }
    return {qixi::NativeKataGoStatusCode::ok, "fake tombstone restored", ""};
  }
};

}  // namespace

int main() {
  std::remove(b6Config().modelPath.c_str());
  std::remove(b18Config().modelPath.c_str());
  writeFile(b6Config().modelPath, "fake-b6-model");
  writeFile(b18Config().modelPath, "fake-b18-model");

  qixi::NativeKataGoCore core;
  expect(!core.isLinked(), "placeholder core must report not linked");

  qixi::NativeKataGoResult none = core.loadEngine("none");
  expect(none.ok(), "none engine loads without a model");

  qixi::NativeKataGoResult noneAnalysis = core.analyzeRequestJSON(emptyAnalysisRequestJSON());
  expect(noneAnalysis.ok(), "none engine returns a decodable no-engine analysis response");
  expect(noneAnalysis.responseJSON.find(R"("engine":"none")") != std::string::npos, "none response names engine");
  expect(noneAnalysis.responseJSON.find(R"("positionKey":"native-none:)") != std::string::npos, "none response has native position key");
  expect(noneAnalysis.responseJSON.find(R"("moves":[])") != std::string::npos, "none response has empty moves");

  const std::string emptyPositionKey = extractPositionKey(noneAnalysis.responseJSON);
  expect(!emptyPositionKey.empty(), "none response exposes a parseable native position key");
  const std::string emptyDifferentVisitsKey = extractPositionKey(
    core.analyzeRequestJSON(R"({"moves":[],"maxVisits":256,"komi":7.5,"rootNoise":0.0})").responseJSON
  );
  const std::string emptyExplicitChineseRulesKey = extractPositionKey(
    core.analyzeRequestJSON(emptyExplicitChineseRulesRequestJSON()).responseJSON
  );
  expect(
    emptyPositionKey == emptyDifferentVisitsKey,
    "native no-engine position key ignores maxVisits because visits do not change the position"
  );
  expect(
    emptyPositionKey == emptyExplicitChineseRulesKey,
    "native no-engine position key treats omitted rules as explicit Chinese rules"
  );
  const std::string emptyDifferentKomiKey = extractPositionKey(
    core.analyzeRequestJSON(emptyWithDifferentKomiRequestJSON()).responseJSON
  );
  expect(
    emptyPositionKey != emptyDifferentKomiKey,
    "native no-engine position key includes komi"
  );
  const std::string emptyRootNoiseKey = extractPositionKey(
    core.analyzeRequestJSON(emptyWithRootNoiseRequestJSON()).responseJSON
  );
  expect(
    emptyPositionKey != emptyRootNoiseKey,
    "native no-engine position key includes root noise"
  );
  const std::string passPositionKey = extractPositionKey(
    core.analyzeRequestJSON(singlePassRequestJSON()).responseJSON
  );
  expect(
    emptyPositionKey != passPositionKey,
    "native no-engine position key includes pass moves"
  );
  const std::string historyAKey = extractPositionKey(
    core.analyzeRequestJSON(sameStonesHistoryARequestJSON()).responseJSON
  );
  const std::string historyAReorderedKey = extractPositionKey(
    core.analyzeRequestJSON(sameStonesHistoryAReorderedRequestJSON()).responseJSON
  );
  const std::string historyADifferentVisitsKey = extractPositionKey(
    core.analyzeRequestJSON(sameStonesHistoryARequestJSON(128)).responseJSON
  );
  const std::string historyBKey = extractPositionKey(
    core.analyzeRequestJSON(sameStonesHistoryBRequestJSON()).responseJSON
  );
  expect(
    historyAKey == historyAReorderedKey && historyAKey == historyADifferentVisitsKey,
    "native no-engine position key canonicalizes field order, whitespace, numeric spelling, and maxVisits"
  );
  expect(
    historyAKey != historyBKey,
    "native no-engine position key distinguishes same stones with different ordered history"
  );

  qixi::NativeKataGoAnalysisRequest defaultRequest{};
  expect(
    hasChineseRules(defaultRequest.rules) &&
      defaultRequest.nextPlayer == qixi::NativeKataGoMoveColor::black &&
      defaultRequest.maxVisits == 0 &&
      defaultRequest.komi == 0.0 &&
      defaultRequest.rootNoise == 0.0 &&
      countBoardPoints(defaultRequest, qixi::NativeKataGoBoardPoint::empty) == 19 * 19,
    "default native analysis request is a safe empty Chinese-rules root"
  );

  qixi::NativeKataGoAnalysisRequest parsedMixed{};
  qixi::NativeKataGoResult parsedMixedResult =
    qixi::parseNativeKataGoAnalysisRequestJSON(mixedAnalysisRequestJSON(), parsedMixed);
  expect(parsedMixedResult.ok(), "native request parser accepts mixed board and pass history");
  expect(
    hasChineseRules(qixi::nativeKataGoChineseRules()) &&
      std::string(qixi::nativeKataGoKoRuleCode(qixi::NativeKataGoKoRule::simple)) == "SIMPLE" &&
      std::string(qixi::nativeKataGoScoringRuleCode(qixi::NativeKataGoScoringRule::area)) == "AREA" &&
      std::string(qixi::nativeKataGoTaxRuleCode(qixi::NativeKataGoTaxRule::none)) == "NONE" &&
      std::string(qixi::nativeKataGoWhiteHandicapBonusRuleCode(qixi::NativeKataGoWhiteHandicapBonusRule::n)) == "N",
    "native request parser exposes canonical Chinese rules helpers for adapters"
  );
  expect(hasChineseRules(parsedMixed.rules), "native request parser defaults requests to KataGo Chinese rules");
  expect(
    std::string(qixi::nativeKataGoMoveColorCode(
      qixi::nativeKataGoOppositeColor(qixi::NativeKataGoMoveColor::black)
    )) == "W" &&
      std::string(qixi::nativeKataGoMoveColorCode(
        qixi::nativeKataGoOppositeColor(qixi::NativeKataGoMoveColor::white)
      )) == "B",
    "native request parser exposes canonical opposite-color helpers for adapters"
  );
  expect(parsedMixed.maxVisits == 64, "native request parser preserves maxVisits for the real adapter");
  expect(parsedMixed.komi == 7.5, "native request parser preserves komi for the real adapter");
  expect(parsedMixed.rootNoise == 0.0, "native request parser preserves root noise for the real adapter");
  expect(parsedMixed.moves.size() == 2, "native request parser preserves ordered move count");
  expect(
    parsedMixed.moves[0].color == qixi::NativeKataGoMoveColor::black &&
      !parsedMixed.moves[0].pass &&
      parsedMixed.moves[0].x == 3 &&
      parsedMixed.moves[0].y == 3,
    "native request parser preserves board move color and coordinates"
  );
  expect(
    parsedMixed.moves[1].color == qixi::NativeKataGoMoveColor::white &&
      parsedMixed.moves[1].pass &&
      parsedMixed.moves[1].x == -1 &&
      parsedMixed.moves[1].y == -1,
    "native request parser preserves pass moves without coordinates"
  );
  expect(
    parsedMixed.nextPlayer == qixi::NativeKataGoMoveColor::black,
    "native request parser derives next player after a white pass"
  );
  expect(
    parsedMixed.finalBoard[boardIndex(3, 3)] == qixi::NativeKataGoBoardPoint::black &&
      countBoardPoints(parsedMixed, qixi::NativeKataGoBoardPoint::black) == 1 &&
      countBoardPoints(parsedMixed, qixi::NativeKataGoBoardPoint::white) == 0,
    "native request parser exposes final board after pass-preserving replay"
  );

  qixi::NativeKataGoAnalysisRequest parsedSetup{};
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(setupStonesRequestJSON(), parsedSetup).ok(),
    "native request parser accepts non-history setup stones"
  );
  expect(
    parsedSetup.moves.empty() &&
      parsedSetup.nextPlayer == qixi::NativeKataGoMoveColor::white,
    "native request parser keeps photographed setup stones out of ordered move history"
  );
  expect(
    parsedSetup.initialBoard[boardIndex(3, 3)] == qixi::NativeKataGoBoardPoint::black &&
      parsedSetup.initialBoard[boardIndex(15, 15)] == qixi::NativeKataGoBoardPoint::white &&
      parsedSetup.finalBoard[boardIndex(3, 3)] == qixi::NativeKataGoBoardPoint::black &&
      parsedSetup.finalBoard[boardIndex(15, 15)] == qixi::NativeKataGoBoardPoint::white &&
      countInitialBoardPoints(parsedSetup, qixi::NativeKataGoBoardPoint::black) == 1 &&
      countInitialBoardPoints(parsedSetup, qixi::NativeKataGoBoardPoint::white) == 1,
    "native request parser exposes setup stones through initialBoard and finalBoard without replaying fake moves"
  );
  expect(
    qixi::nativeKataGoPositionKeyMaterial(parsedSetup) !=
      qixi::nativeKataGoPositionKeyMaterial(parsedMixed),
    "native canonical material keeps setup stones distinct from ordered move history"
  );

  qixi::NativeKataGoAnalysisRequest parsedIllegal{};
  qixi::NativeKataGoAnalysisRequest parsedEmpty{};
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(emptyAnalysisRequestJSON(), parsedEmpty).ok() &&
      parsedEmpty.nextPlayer == qixi::NativeKataGoMoveColor::black,
    "native request parser derives black as next player for an empty board"
  );
  qixi::NativeKataGoAnalysisRequest parsedExplicitChineseRules{};
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(
      emptyExplicitChineseRulesRequestJSON(),
      parsedExplicitChineseRules
    ).ok() &&
      hasChineseRules(parsedExplicitChineseRules.rules),
    "native request parser accepts explicit Chinese rules"
  );
  expect(
    qixi::nativeKataGoPositionKeyMaterial(parsedEmpty) ==
      qixi::nativeKataGoPositionKeyMaterial(parsedExplicitChineseRules),
    "native request parser canonical material treats omitted rules as explicit Chinese rules"
  );
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(emptyUnsupportedRulesRequestJSON(), parsedIllegal).code ==
      qixi::NativeKataGoStatusCode::invalidRequest,
    "native request parser rejects unsupported rules before the adapter"
  );
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(duplicateSetupStonesRequestJSON(), parsedIllegal).code ==
      qixi::NativeKataGoStatusCode::invalidRequest,
    "native request parser rejects duplicate setup stones before the adapter"
  );
  expect(
    countBoardPoints(parsedEmpty, qixi::NativeKataGoBoardPoint::black) == 0 &&
      countBoardPoints(parsedEmpty, qixi::NativeKataGoBoardPoint::white) == 0,
    "native request parser exposes an empty final board for an empty history"
  );

  qixi::NativeKataGoAnalysisRequest parsedSinglePass{};
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(singlePassRequestJSON(), parsedSinglePass).ok() &&
      parsedSinglePass.nextPlayer == qixi::NativeKataGoMoveColor::white,
    "native request parser derives next player after a black pass"
  );
  expect(
    countBoardPoints(parsedSinglePass, qixi::NativeKataGoBoardPoint::black) == 0 &&
      countBoardPoints(parsedSinglePass, qixi::NativeKataGoBoardPoint::white) == 0,
    "native request parser keeps pass-only final board empty"
  );

  qixi::NativeKataGoAnalysisRequest parsedRepeated{};
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(legalRepeatedCoordinateAfterCaptureRequestJSON(), parsedRepeated).ok(),
    "native request parser accepts legal repeated board coordinates after capture"
  );
  expect(
    parsedRepeated.moves.size() == 6 &&
      parsedRepeated.moves[0].x == parsedRepeated.moves[5].x &&
      parsedRepeated.moves[0].y == parsedRepeated.moves[5].y,
    "native request parser keeps repeated coordinates instead of collapsing to a board bitmap"
  );
  expect(
    parsedRepeated.nextPlayer == qixi::NativeKataGoMoveColor::white,
    "native request parser derives next player from the ordered repeated-coordinate history"
  );
  expect(
    parsedRepeated.finalBoard[boardIndex(1, 1)] == qixi::NativeKataGoBoardPoint::black &&
      countBoardPoints(parsedRepeated, qixi::NativeKataGoBoardPoint::black) == 5 &&
      countBoardPoints(parsedRepeated, qixi::NativeKataGoBoardPoint::white) == 0,
    "native request parser exposes final board after capture and legal coordinate reuse"
  );
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(occupiedPointIllegalRequestJSON(), parsedIllegal).code ==
      qixi::NativeKataGoStatusCode::invalidRequest,
    "native request parser rejects board histories that play on an occupied point"
  );
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(suicideIllegalRequestJSON(), parsedIllegal).code ==
      qixi::NativeKataGoStatusCode::invalidRequest,
    "native request parser rejects suicide board histories before the adapter"
  );
  expect(
    qixi::parseNativeKataGoAnalysisRequestJSON(simpleKoIllegalRequestJSON(), parsedIllegal).code ==
      qixi::NativeKataGoStatusCode::invalidRequest,
    "native request parser rejects immediate simple-ko recapture before the adapter"
  );

  qixi::NativeKataGoAnalysisRequest parsedHistoryA{};
  qixi::NativeKataGoAnalysisRequest parsedHistoryAReordered{};
  qixi::NativeKataGoAnalysisRequest parsedHistoryB{};
  expect(qixi::parseNativeKataGoAnalysisRequestJSON(sameStonesHistoryARequestJSON(), parsedHistoryA).ok(), "native request parser accepts history A");
  expect(qixi::parseNativeKataGoAnalysisRequestJSON(sameStonesHistoryAReorderedRequestJSON(), parsedHistoryAReordered).ok(), "native request parser accepts reordered JSON fields for history A");
  expect(qixi::parseNativeKataGoAnalysisRequestJSON(sameStonesHistoryBRequestJSON(), parsedHistoryB).ok(), "native request parser accepts history B");
  expect(
    qixi::nativeKataGoPositionKeyMaterial(parsedHistoryA) ==
      qixi::nativeKataGoPositionKeyMaterial(parsedHistoryAReordered),
    "native request parser canonical material ignores JSON field order and numeric spelling"
  );
  expect(
    qixi::nativeKataGoPositionKeyMaterial(parsedHistoryA) !=
      qixi::nativeKataGoPositionKeyMaterial(parsedHistoryB),
    "native request parser canonical material distinguishes same stones with different ordered history"
  );

  expect(
    core.exportTombstoneToFile("").code == qixi::NativeKataGoStatusCode::invalidRequest,
    "empty native tombstone export path is rejected"
  );
  const std::string noEngineTombstonePath = tempPath("qixi-native-no-engine-tombstone-smoke.json");
  std::remove(noEngineTombstonePath.c_str());
  expect(core.exportTombstoneToFile(noEngineTombstonePath).ok(), "no-engine native tombstone exports to disk");
  const std::string noEngineTombstone = readFile(noEngineTombstonePath);
  expect(
    noEngineTombstone.find(R"("kind":"qixi-native-katago-tombstone")") != std::string::npos &&
      noEngineTombstone.find(R"("engine":"none")") != std::string::npos,
    "no-engine native tombstone records schema and engine"
  );
  expect(core.restoreTombstoneFromFile(noEngineTombstonePath).ok(), "no-engine native tombstone restores from disk");

  const std::string noEngineTombstoneDirectoryPath = tempPath("qixi-native-no-engine-tombstone-directory-smoke.json");
  std::remove(noEngineTombstoneDirectoryPath.c_str());
  mkdir(noEngineTombstoneDirectoryPath.c_str(), 0700);
  expect(
    core.exportTombstoneToFile(noEngineTombstoneDirectoryPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "no-engine native tombstone export rejects directory paths"
  );
  expect(
    core.restoreTombstoneFromFile(noEngineTombstoneDirectoryPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "no-engine native tombstone restore rejects directory paths"
  );
  rmdir(noEngineTombstoneDirectoryPath.c_str());

  const std::string noEngineTombstoneSymlinkTargetPath = tempPath("qixi-native-no-engine-tombstone-symlink-target-smoke.json");
  const std::string noEngineTombstoneSymlinkPath = tempPath("qixi-native-no-engine-tombstone-symlink-smoke.json");
  writeFile(noEngineTombstoneSymlinkTargetPath, "do-not-overwrite");
  std::remove(noEngineTombstoneSymlinkPath.c_str());
  expect(
    symlink(noEngineTombstoneSymlinkTargetPath.c_str(), noEngineTombstoneSymlinkPath.c_str()) == 0,
    "test fixture creates a no-engine tombstone symlink path"
  );
  expect(
    core.exportTombstoneToFile(noEngineTombstoneSymlinkPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "no-engine native tombstone export rejects symbolic-link paths"
  );
  expect(
    readFile(noEngineTombstoneSymlinkTargetPath) == "do-not-overwrite",
    "no-engine native tombstone export does not overwrite symbolic-link targets"
  );
  expect(
    core.restoreTombstoneFromFile(noEngineTombstoneSymlinkPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "no-engine native tombstone restore rejects symbolic-link paths"
  );
  std::remove(noEngineTombstoneSymlinkPath.c_str());
  std::remove(noEngineTombstoneSymlinkTargetPath.c_str());

  const std::string prettyNoEngineTombstonePath = tempPath("qixi-native-no-engine-tombstone-pretty-smoke.json");
  {
    std::ofstream prettyOut(prettyNoEngineTombstonePath, std::ios::binary | std::ios::trunc);
    prettyOut << "{\n"
      << "  \"schemaVersion\": 1,\n"
      << "  \"kind\": \"qixi-native-katago-tombstone\",\n"
      << "  \"engine\": \"none\",\n"
      << "  \"state\": \"seeded restore smoke\"\n"
      << "}\n";
  }
  expect(
    core.restoreTombstoneFromFile(prettyNoEngineTombstonePath).ok(),
    "no-engine native tombstone restore accepts valid JSON whitespace"
  );
  const std::string malformedNoEngineTombstonePath = tempPath("qixi-native-no-engine-tombstone-malformed-smoke.json");
  {
    std::ofstream badOut(malformedNoEngineTombstonePath, std::ios::binary | std::ios::trunc);
    badOut << R"({"schemaVersion":1,"kind":"qixi-native-katago-tombstone","engine":"b6","state":"wrong engine"})";
  }
  expect(
    core.restoreTombstoneFromFile(malformedNoEngineTombstonePath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "no-engine native tombstone restore rejects the wrong engine"
  );

  const std::string oversizedNoEngineTombstonePath = tempPath("qixi-native-no-engine-tombstone-oversized-smoke.json");
  writeSparseFile(oversizedNoEngineTombstonePath, kOversizedNativeTombstoneBytes);
  qixi::NativeKataGoResult oversizedNoEngineRestore =
    core.restoreTombstoneFromFile(oversizedNoEngineTombstonePath);
  expect(
    oversizedNoEngineRestore.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "no-engine native tombstone restore rejects oversized tombstone before loading"
  );
  expect(
    oversizedNoEngineRestore.message.find("bounded restore size") != std::string::npos,
    "no-engine native tombstone restore explains oversized tombstone bounds"
  );
  std::remove(oversizedNoEngineTombstonePath.c_str());

  qixi::NativeKataGoResult missingConfig = core.loadEngine("b6");
  expect(missingConfig.code == qixi::NativeKataGoStatusCode::invalidRequest, "b6 requires model config before load");

  qixi::NativeKataGoModelConfig badEngine = b6Config();
  badEngine.engineID = "mock";
  expect(
    core.configureModel(badEngine).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "unsupported engine id is rejected"
  );

  qixi::NativeKataGoModelConfig badBudget = b6Config();
  badBudget.minimumMemoryMB = 1024;
  badBudget.recommendedMemoryMB = 512;
  expect(
    core.configureModel(badBudget).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "unordered memory budgets are rejected"
  );

  qixi::NativeKataGoModelConfig badPath = b6Config();
  badPath.modelPath = "/tmp/wrong-model.bin.gz";
  expect(
    core.configureModel(badPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "model path must end with the resource name"
  );

  qixi::NativeKataGoModelConfig missingModelPath = b6Config();
  missingModelPath.modelPath = tempPath("missing-g170-b6c96-s175395328-d26788732.bin.gz");
  std::remove(missingModelPath.modelPath.c_str());
  expect(
    core.configureModel(missingModelPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "model path must point to a readable file"
  );

  qixi::NativeKataGoModelConfig emptyModelPath = b6Config();
  emptyModelPath.modelPath = tempPath("empty-g170-b6c96-s175395328-d26788732.bin.gz");
  writeFile(emptyModelPath.modelPath, "");
  expect(
    core.configureModel(emptyModelPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "model path must point to a non-empty file"
  );

  qixi::NativeKataGoModelConfig directoryModelPath = b6Config();
  directoryModelPath.modelPath = tempPath("directory-g170-b6c96-s175395328-d26788732.bin.gz");
  std::remove(directoryModelPath.modelPath.c_str());
  mkdir(directoryModelPath.modelPath.c_str(), 0700);
  expect(
    core.configureModel(directoryModelPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "model path must point to a regular file, not a directory"
  );
  rmdir(directoryModelPath.modelPath.c_str());

  qixi::NativeKataGoModelConfig symlinkModelPath = b6Config();
  symlinkModelPath.modelPath = tempPath("symlink-g170-b6c96-s175395328-d26788732.bin.gz");
  std::remove(symlinkModelPath.modelPath.c_str());
  expect(
    symlink(b6Config().modelPath.c_str(), symlinkModelPath.modelPath.c_str()) == 0,
    "test fixture creates a symlink-shaped model path"
  );
  expect(
    core.configureModel(symlinkModelPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "model path must point to a regular file, not a symbolic link"
  );
  std::remove(symlinkModelPath.modelPath.c_str());

  qixi::NativeKataGoModelConfig emptyCoreMLPackagePath = b6Config();
  emptyCoreMLPackagePath.coreMLPackagePaths = {""};
  expect(
    core.configureModel(emptyCoreMLPackagePath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "CoreML package path must not be empty"
  );

  qixi::NativeKataGoModelConfig missingCoreMLPackagePath = b6Config();
  missingCoreMLPackagePath.coreMLPackagePaths = {tempPath("missing-b6-coreml.mlpackage")};
  std::remove(missingCoreMLPackagePath.coreMLPackagePaths.front().c_str());
  expect(
    core.configureModel(missingCoreMLPackagePath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "CoreML package path must point to a readable directory"
  );

  qixi::NativeKataGoModelConfig fileCoreMLPackagePath = b6Config();
  fileCoreMLPackagePath.coreMLPackagePaths = {tempPath("file-b6-coreml.mlpackage")};
  writeFile(fileCoreMLPackagePath.coreMLPackagePaths.front(), "not a package directory");
  expect(
    core.configureModel(fileCoreMLPackagePath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "CoreML package path must point to a directory, not a file"
  );
  std::remove(fileCoreMLPackagePath.coreMLPackagePaths.front().c_str());

  qixi::NativeKataGoModelConfig symlinkCoreMLPackagePath = b6Config();
  symlinkCoreMLPackagePath.coreMLPackagePaths = {tempPath("symlink-b6-coreml.mlpackage")};
  std::remove(symlinkCoreMLPackagePath.coreMLPackagePaths.front().c_str());
  expect(
    symlink(b6Config().modelPath.c_str(), symlinkCoreMLPackagePath.coreMLPackagePaths.front().c_str()) == 0,
    "test fixture creates a symlink-shaped CoreML package path"
  );
  expect(
    core.configureModel(symlinkCoreMLPackagePath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "CoreML package path must point to a directory, not a symbolic link"
  );
  std::remove(symlinkCoreMLPackagePath.coreMLPackagePaths.front().c_str());

  qixi::NativeKataGoModelConfig validCoreMLPackagePath = b6Config();
  const std::string validCoreMLPackageDirectory = tempPath("valid-b6-coreml.mlpackage");
  const std::string validCoreMLPackageFile = validCoreMLPackageDirectory + "/Manifest.json";
  std::remove(validCoreMLPackageFile.c_str());
  rmdir(validCoreMLPackageDirectory.c_str());
  mkdir(validCoreMLPackageDirectory.c_str(), 0700);
  writeFile(validCoreMLPackageFile, "{}");
  validCoreMLPackagePath.coreMLPackagePaths = {validCoreMLPackageDirectory};
  expect(
    core.configureModel(validCoreMLPackagePath).ok(),
    "valid b6 model config accepts a verified CoreML package directory path"
  );
  std::remove(validCoreMLPackageFile.c_str());
  rmdir(validCoreMLPackageDirectory.c_str());

  expect(core.configureModel(b6Config()).ok(), "valid b6 model config is accepted");
  qixi::NativeKataGoResult linkedLoad = core.loadEngine("b6");
  expect(
    linkedLoad.code == qixi::NativeKataGoStatusCode::libraryNotLinked,
    "configured real engine reaches the not-linked boundary"
  );

  qixi::NativeKataGoResult emptyRequest = core.analyzeRequestJSON("");
  expect(
    emptyRequest.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "empty analysis JSON is rejected"
  );

  qixi::NativeKataGoResult malformedNoneRequest = core.analyzeRequestJSON(R"({"moves":[{"color":"B","x":19,"y":3}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})");
  expect(
    malformedNoneRequest.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "malformed native analysis request is rejected before no-engine response"
  );

  auto noneUnloadEngine = std::make_unique<FakeNativeKataGoEngine>();
  FakeNativeKataGoEngine* noneUnloadEnginePtr = noneUnloadEngine.get();
  qixi::NativeKataGoCore noneUnloadCore(std::move(noneUnloadEngine));
  expect(noneUnloadCore.configureModel(b6Config()).ok(), "none unload core accepts valid b6 model config");
  expect(noneUnloadCore.loadEngine("b6").ok(), "none unload core loads b6");
  expect(
    noneUnloadEnginePtr->unloadModelCalls == 1 &&
      noneUnloadEnginePtr->loadModelCalls == 1,
    "real-engine load performs an idempotent adapter unload before loading the model"
  );
  expect(noneUnloadCore.loadEngine("none").ok(), "loading none unloads a previously loaded real adapter");
  expect(
    noneUnloadEnginePtr->unloadModelCalls == 2,
    "loading none delegates adapter unload exactly once after a real model was loaded"
  );
  qixi::NativeKataGoResult analysisAfterExplicitNone = noneUnloadCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
  expect(
    analysisAfterExplicitNone.ok() &&
      analysisAfterExplicitNone.responseJSON.find(R"("engine":"none")") != std::string::npos,
    "analysis after explicit none unload returns a no-engine response"
  );
  expect(
    noneUnloadEnginePtr->analyzeCalls == 0,
    "analysis after explicit none unload must not call the unloaded adapter"
  );

  auto failingUnloadEngine = std::make_unique<FakeNativeKataGoEngine>();
  FakeNativeKataGoEngine* failingUnloadEnginePtr = failingUnloadEngine.get();
  qixi::NativeKataGoCore failingUnloadCore(std::move(failingUnloadEngine));
  expect(failingUnloadCore.configureModel(b6Config()).ok(), "failing-unload core accepts valid b6 model config");
  expect(failingUnloadCore.configureModel(b18Config()).ok(), "failing-unload core accepts valid b18 model config");
  expect(failingUnloadCore.loadEngine("b6").ok(), "failing-unload core loads b6");
  failingUnloadEnginePtr->failUnloadModel = true;
  qixi::NativeKataGoResult failedUnloadSwitch = failingUnloadCore.loadEngine("b18nbt");
  expect(
    failedUnloadSwitch.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "linked core surfaces adapter unload failure before switching engines"
  );
  expect(
    failingUnloadEnginePtr->loadModelCalls == 1,
    "adapter loadModel for the next engine is not called after unload failure"
  );
  qixi::NativeKataGoResult analysisAfterFailedUnloadSwitch =
    failingUnloadCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
  expect(
    analysisAfterFailedUnloadSwitch.ok() &&
      analysisAfterFailedUnloadSwitch.responseJSON.find(R"("engine":"none")") != std::string::npos,
    "failed adapter unload clears loaded engine before any later analysis"
  );
  expect(
    failingUnloadEnginePtr->analyzeCalls == 0,
    "analysis after adapter unload failure must not call the stale adapter model"
  );

  auto fakeEngine = std::make_unique<FakeNativeKataGoEngine>();
  FakeNativeKataGoEngine* fakeEnginePtr = fakeEngine.get();
  qixi::NativeKataGoCore linkedCore(std::move(fakeEngine));
  expect(linkedCore.isLinked(), "injected native engine reports linked");
  const std::string linkedCoreMLPackageDirectory = tempPath("linked-b6-coreml.mlpackage");
  const std::string linkedCoreMLPackageFile = linkedCoreMLPackageDirectory + "/Manifest.json";
  std::remove(linkedCoreMLPackageFile.c_str());
  rmdir(linkedCoreMLPackageDirectory.c_str());
  mkdir(linkedCoreMLPackageDirectory.c_str(), 0700);
  writeFile(linkedCoreMLPackageFile, "{}");
  qixi::NativeKataGoModelConfig linkedB6Config = b6Config();
  linkedB6Config.coreMLPackagePaths = {linkedCoreMLPackageDirectory};
  expect(linkedCore.configureModel(linkedB6Config).ok(), "linked core accepts valid b6 model config with CoreML package paths");
  qixi::NativeKataGoResult fakeLoad = linkedCore.loadEngine("b6");
  expect(fakeLoad.ok(), "linked core delegates real engine load to adapter");
  expect(fakeEnginePtr->unloadModelCalls == 1, "adapter unloadModel is called before a real model load");
  expect(fakeEnginePtr->loadModelCalls == 1, "adapter loadModel is called once");
  expect(fakeEnginePtr->loadedConfig.resourceName == b6Config().resourceName, "adapter receives the configured model resource");
  expect(
    fakeEnginePtr->loadedConfig.coreMLPackagePaths == linkedB6Config.coreMLPackagePaths,
    "adapter receives verified CoreML package paths from the configured model"
  );
  std::remove(linkedCoreMLPackageFile.c_str());
  rmdir(linkedCoreMLPackageDirectory.c_str());
  qixi::NativeKataGoResult fakeAnalysis = linkedCore.analyzeRequestJSON(mixedAnalysisRequestJSON());
  expect(fakeAnalysis.ok(), "linked core delegates analysis to adapter after loading");
  expect(fakeEnginePtr->analyzeCalls == 1, "adapter analyzeRequest is called once with a parsed request");
  expect(fakeEnginePtr->lastRequest.maxVisits == 64, "adapter receives parsed maxVisits");
  expect(
    fakeEnginePtr->lastRequest.nextPlayer == qixi::NativeKataGoMoveColor::black,
    "adapter receives parsed next player instead of inferring root player itself"
  );
  expect(
    hasChineseRules(fakeEnginePtr->lastRequest.rules),
    "adapter receives parsed KataGo Chinese rules instead of relying on implicit config defaults"
  );
  expect(
    fakeEnginePtr->lastRequest.finalBoard[boardIndex(3, 3)] == qixi::NativeKataGoBoardPoint::black,
    "adapter receives parser-derived final board instead of replaying JSON itself"
  );
  expect(
    fakeEnginePtr->lastRequest.moves.size() == 2 &&
      fakeEnginePtr->lastRequest.moves[1].pass &&
      fakeEnginePtr->lastRequest.moves[1].color == qixi::NativeKataGoMoveColor::white,
    "adapter receives parsed pass moves"
  );
  expect(fakeAnalysis.responseJSON.find(R"("engine":"b6")") != std::string::npos, "adapter response is surfaced");

  const std::string fakeTombstoneDirectoryPath = tempPath("qixi-native-fake-engine-tombstone-directory-smoke.bin");
  std::remove(fakeTombstoneDirectoryPath.c_str());
  mkdir(fakeTombstoneDirectoryPath.c_str(), 0700);
  expect(
    linkedCore.exportTombstoneToFile(fakeTombstoneDirectoryPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "linked core rejects directory tombstone export paths before adapter calls"
  );
  expect(fakeEnginePtr->exportTombstoneCalls == 0, "directory tombstone export path does not call adapter");
  rmdir(fakeTombstoneDirectoryPath.c_str());

  const std::string fakeTombstoneSymlinkTargetPath = tempPath("qixi-native-fake-engine-tombstone-symlink-target-smoke.bin");
  const std::string fakeTombstoneSymlinkPath = tempPath("qixi-native-fake-engine-tombstone-symlink-smoke.bin");
  writeFile(fakeTombstoneSymlinkTargetPath, "do-not-overwrite");
  std::remove(fakeTombstoneSymlinkPath.c_str());
  expect(
    symlink(fakeTombstoneSymlinkTargetPath.c_str(), fakeTombstoneSymlinkPath.c_str()) == 0,
    "test fixture creates a linked tombstone symlink path"
  );
  expect(
    linkedCore.exportTombstoneToFile(fakeTombstoneSymlinkPath).code == qixi::NativeKataGoStatusCode::invalidRequest,
    "linked core rejects symbolic-link tombstone export paths before adapter calls"
  );
  expect(fakeEnginePtr->exportTombstoneCalls == 0, "symbolic-link tombstone export path does not call adapter");
  expect(
    readFile(fakeTombstoneSymlinkTargetPath) == "do-not-overwrite",
    "linked tombstone export does not overwrite symbolic-link targets"
  );
  std::remove(fakeTombstoneSymlinkPath.c_str());
  std::remove(fakeTombstoneSymlinkTargetPath.c_str());

  const std::string fakeTombstonePath = tempPath("qixi-native-fake-engine-tombstone-smoke.bin");
  std::remove(fakeTombstonePath.c_str());
  expect(linkedCore.exportTombstoneToFile(fakeTombstonePath).ok(), "linked core delegates native tombstone export to adapter");
  expect(
    fakeEnginePtr->exportTombstoneCalls == 1 &&
      fakeEnginePtr->lastExportTombstonePath == fakeTombstonePath &&
      readFile(fakeTombstonePath) == "fake-native-tombstone",
    "adapter receives native tombstone export path"
  );
  expect(linkedCore.restoreTombstoneFromFile(fakeTombstonePath).ok(), "linked core delegates native tombstone restore to adapter");
  expect(
    fakeEnginePtr->restoreTombstoneCalls == 1 &&
      fakeEnginePtr->lastRestoreTombstonePath == fakeTombstonePath,
    "adapter receives native tombstone restore path"
  );

  auto expectBogusAdapterExportIsRejected = [](bool writeEmpty, const std::string& context) {
    auto exportEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* exportEnginePtr = exportEngine.get();
    exportEnginePtr->skipExportTombstoneWrite = !writeEmpty;
    exportEnginePtr->writeEmptyTombstone = writeEmpty;
    qixi::NativeKataGoCore exportCore(std::move(exportEngine));
    expect(exportCore.configureModel(b6Config()).ok(), context + ": valid b6 model config is accepted");
    expect(exportCore.loadEngine("b6").ok(), context + ": fake adapter loads");
    const std::string bogusPath = tempPath(context + "-qixi-native-fake-engine-tombstone-smoke.bin");
    std::remove(bogusPath.c_str());
    qixi::NativeKataGoResult bogusExport = exportCore.exportTombstoneToFile(bogusPath);
    expect(
      bogusExport.code == qixi::NativeKataGoStatusCode::invalidRequest,
      context + ": adapter tombstone export must not be accepted without a readable non-empty file"
    );
    expect(
      bogusExport.message.find("readable non-empty regular tombstone file") != std::string::npos,
      context + ": adapter tombstone export failure explains the missing file contract"
    );
    expect(exportEnginePtr->exportTombstoneCalls == 1, context + ": fake adapter export is still called exactly once");
    qixi::NativeKataGoResult afterBogusExport = exportCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
    expect(
      afterBogusExport.ok() &&
        afterBogusExport.responseJSON.find(R"("engine":"b6")") != std::string::npos,
      context + ": failed tombstone export does not unload a still-valid adapter"
    );
  };

  expectBogusAdapterExportIsRejected(false, "missing real-engine tombstone file");
  expectBogusAdapterExportIsRejected(true, "empty real-engine tombstone file");

  auto expectOversizedAdapterExportIsRejected = []() {
    auto exportEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* exportEnginePtr = exportEngine.get();
    exportEnginePtr->writeOversizedTombstone = true;
    qixi::NativeKataGoCore exportCore(std::move(exportEngine));
    expect(exportCore.configureModel(b6Config()).ok(), "oversized real-engine tombstone export: valid b6 model config is accepted");
    expect(exportCore.loadEngine("b6").ok(), "oversized real-engine tombstone export: fake adapter loads");
    const std::string oversizedPath = tempPath("qixi-native-fake-engine-tombstone-oversized-export-smoke.bin");
    std::remove(oversizedPath.c_str());
    qixi::NativeKataGoResult oversizedExport = exportCore.exportTombstoneToFile(oversizedPath);
    expect(
      oversizedExport.code == qixi::NativeKataGoStatusCode::invalidRequest,
      "oversized real-engine tombstone export is rejected after adapter write"
    );
    expect(
      oversizedExport.message.find("exceeding the bounded size") != std::string::npos,
      "oversized real-engine tombstone export explains bounded file size"
    );
    expect(exportEnginePtr->exportTombstoneCalls == 1, "oversized real-engine tombstone export still calls adapter exactly once");
    qixi::NativeKataGoResult afterOversizedExport = exportCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
    expect(
      afterOversizedExport.ok() &&
        afterOversizedExport.responseJSON.find(R"("engine":"b6")") != std::string::npos,
      "oversized real-engine tombstone export does not unload a still-valid adapter"
    );
    std::remove(oversizedPath.c_str());
  };

  expectOversizedAdapterExportIsRejected();

  auto expectUnreadableAdapterRestoreIsRejected = [](bool createEmpty, const std::string& context) {
    auto restoreEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* restoreEnginePtr = restoreEngine.get();
    qixi::NativeKataGoCore restoreCore(std::move(restoreEngine));
    expect(restoreCore.configureModel(b6Config()).ok(), context + ": valid b6 model config is accepted");
    expect(restoreCore.loadEngine("b6").ok(), context + ": fake adapter loads");
    const std::string unreadablePath = tempPath(context + "-qixi-native-fake-engine-tombstone-smoke.bin");
    std::remove(unreadablePath.c_str());
    if(createEmpty) {
      std::ofstream out(unreadablePath, std::ios::binary | std::ios::trunc);
    }
    qixi::NativeKataGoResult unreadableRestore = restoreCore.restoreTombstoneFromFile(unreadablePath);
    expect(
      unreadableRestore.code == qixi::NativeKataGoStatusCode::invalidRequest,
      context + ": real-engine tombstone restore must not be accepted without a readable non-empty file"
    );
    expect(
      unreadableRestore.message.find("readable non-empty regular file") != std::string::npos,
      context + ": unreadable real-engine tombstone restore explains the source file contract"
    );
    expect(
      restoreEnginePtr->restoreTombstoneCalls == 0,
      context + ": real-engine tombstone restore must not call adapter without a readable non-empty file"
    );
    expect(
      restoreEnginePtr->unloadModelCalls == 2,
      context + ": unreadable real-engine tombstone restore unloads the loaded adapter model"
    );
    qixi::NativeKataGoResult afterUnreadableRestore = restoreCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
    expect(
      afterUnreadableRestore.ok() &&
        afterUnreadableRestore.responseJSON.find(R"("engine":"none")") != std::string::npos,
      context + ": unreadable real-engine tombstone restore clears loaded engine"
    );
    expect(
      restoreEnginePtr->analyzeCalls == 0,
      context + ": analysis after unreadable restore must not call the stale adapter model"
    );
    expect(restoreCore.loadEngine("b6").ok(), context + ": linked core can reload b6 after unreadable tombstone restore");
  };

  expectUnreadableAdapterRestoreIsRejected(false, "missing real-engine tombstone restore file");
  expectUnreadableAdapterRestoreIsRejected(true, "empty real-engine tombstone restore file");

  auto expectOversizedAdapterRestoreIsRejected = []() {
    auto restoreEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* restoreEnginePtr = restoreEngine.get();
    qixi::NativeKataGoCore restoreCore(std::move(restoreEngine));
    expect(restoreCore.configureModel(b6Config()).ok(), "oversized real-engine tombstone restore: valid b6 model config is accepted");
    expect(restoreCore.loadEngine("b6").ok(), "oversized real-engine tombstone restore: fake adapter loads");
    const std::string oversizedPath = tempPath("qixi-native-fake-engine-tombstone-oversized-restore-smoke.bin");
    writeSparseFile(oversizedPath, kOversizedNativeTombstoneBytes);
    qixi::NativeKataGoResult oversizedRestore = restoreCore.restoreTombstoneFromFile(oversizedPath);
    expect(
      oversizedRestore.code == qixi::NativeKataGoStatusCode::invalidRequest,
      "oversized real-engine tombstone restore is rejected before adapter calls"
    );
    expect(
      oversizedRestore.message.find("bounded restore size") != std::string::npos,
      "oversized real-engine tombstone restore explains bounded file size"
    );
    expect(
      restoreEnginePtr->restoreTombstoneCalls == 0,
      "oversized real-engine tombstone restore must not call adapter before bounded read"
    );
    expect(
      restoreEnginePtr->unloadModelCalls == 2,
      "oversized real-engine tombstone restore unloads the loaded adapter model"
    );
    qixi::NativeKataGoResult afterOversizedRestore = restoreCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
    expect(
      afterOversizedRestore.ok() &&
        afterOversizedRestore.responseJSON.find(R"("engine":"none")") != std::string::npos,
      "oversized real-engine tombstone restore clears loaded engine"
    );
    expect(
      restoreEnginePtr->analyzeCalls == 0,
      "analysis after oversized real-engine tombstone restore must not call the stale adapter model"
    );
    expect(restoreCore.loadEngine("b6").ok(), "linked core can reload b6 after oversized tombstone restore");
    std::remove(oversizedPath.c_str());
  };

  expectOversizedAdapterRestoreIsRejected();

  auto expectNonRegularAdapterRestoreIsRejected = [](bool useSymlink, const std::string& context) {
    auto restoreEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* restoreEnginePtr = restoreEngine.get();
    qixi::NativeKataGoCore restoreCore(std::move(restoreEngine));
    expect(restoreCore.configureModel(b6Config()).ok(), context + ": valid b6 model config is accepted");
    expect(restoreCore.loadEngine("b6").ok(), context + ": fake adapter loads");
    const std::string path = tempPath(context + "-qixi-native-fake-engine-tombstone-smoke.bin");
    std::remove(path.c_str());
    std::string symlinkTargetPath;
    if(useSymlink) {
      symlinkTargetPath = tempPath(context + "-qixi-native-fake-engine-tombstone-target-smoke.bin");
      writeFile(symlinkTargetPath, "fake-native-tombstone");
      expect(symlink(symlinkTargetPath.c_str(), path.c_str()) == 0, context + ": test fixture creates a restore symlink path");
    } else {
      mkdir(path.c_str(), 0700);
    }
    qixi::NativeKataGoResult nonRegularRestore = restoreCore.restoreTombstoneFromFile(path);
    expect(
      nonRegularRestore.code == qixi::NativeKataGoStatusCode::invalidRequest,
      context + ": real-engine tombstone restore rejects non-regular files"
    );
    expect(
      restoreEnginePtr->restoreTombstoneCalls == 0,
      context + ": non-regular real-engine tombstone restore must not call adapter"
    );
    expect(
      restoreEnginePtr->unloadModelCalls == 2,
      context + ": non-regular real-engine tombstone restore unloads the loaded adapter model"
    );
    qixi::NativeKataGoResult afterNonRegularRestore = restoreCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
    expect(
      afterNonRegularRestore.ok() &&
        afterNonRegularRestore.responseJSON.find(R"("engine":"none")") != std::string::npos,
      context + ": non-regular real-engine tombstone restore clears loaded engine"
    );
    if(useSymlink) {
      std::remove(path.c_str());
      std::remove(symlinkTargetPath.c_str());
    } else {
      rmdir(path.c_str());
    }
  };

  expectNonRegularAdapterRestoreIsRejected(false, "directory real-engine tombstone restore file");
  expectNonRegularAdapterRestoreIsRejected(true, "symbolic-link real-engine tombstone restore file");

  fakeEnginePtr->failRestoreTombstone = true;
  const int unloadsBeforeFailedRestore = fakeEnginePtr->unloadModelCalls;
  qixi::NativeKataGoResult failedRestore = linkedCore.restoreTombstoneFromFile(fakeTombstonePath);
  expect(
    failedRestore.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "linked core surfaces native tombstone restore failure"
  );
  expect(
    fakeEnginePtr->unloadModelCalls == unloadsBeforeFailedRestore + 1 &&
      fakeEnginePtr->loadedConfig.engineID.empty(),
    "linked core unloads the adapter model after native tombstone restore failure"
  );
  qixi::NativeKataGoResult analysisAfterFailedRestore = linkedCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
  expect(
    analysisAfterFailedRestore.ok() &&
      analysisAfterFailedRestore.responseJSON.find(R"("engine":"none")") != std::string::npos,
    "linked core clears loaded engine after native tombstone restore failure"
  );
  expect(
    fakeEnginePtr->analyzeCalls == 1,
    "analysis after native tombstone restore failure must not call the stale adapter model"
  );
  fakeEnginePtr->failRestoreTombstone = false;
  expect(linkedCore.loadEngine("b6").ok(), "linked core can reload b6 after a failed tombstone restore");

  const int unloadsBeforeMissingConfigSwitch = fakeEnginePtr->unloadModelCalls;
  qixi::NativeKataGoResult missingSwitchConfig = linkedCore.loadEngine("b28nbt");
  expect(
    missingSwitchConfig.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "linked core surfaces missing config while switching engines"
  );
  expect(
    fakeEnginePtr->unloadModelCalls == unloadsBeforeMissingConfigSwitch + 1,
    "missing-config engine switch unloads the previously loaded adapter model"
  );
  qixi::NativeKataGoResult analysisAfterMissingConfigSwitch = linkedCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
  expect(
    analysisAfterMissingConfigSwitch.ok(),
    "analysis after a missing-config engine switch returns a safe no-engine response"
  );
  expect(
    analysisAfterMissingConfigSwitch.responseJSON.find(R"("engine":"none")") != std::string::npos,
    "missing-config engine switch clears the previous loaded engine"
  );
  expect(
    fakeEnginePtr->analyzeCalls == 1,
    "analysis after a missing-config engine switch must not call the stale adapter model"
  );

  expect(linkedCore.loadEngine("b6").ok(), "linked core can reload b6 after a failed switch");
  qixi::NativeKataGoResult fakeAnalysisAfterReload = linkedCore.analyzeRequestJSON(mixedAnalysisRequestJSON());
  expect(fakeAnalysisAfterReload.ok(), "linked core delegates analysis after reloading b6");
  expect(fakeEnginePtr->analyzeCalls == 2, "adapter analyzeRequest is called again after reloading b6");

  expect(linkedCore.configureModel(b18Config()).ok(), "linked core accepts valid b18 model config");
  fakeEnginePtr->engineIDToFailOnLoad = "b18nbt";
  const int unloadsBeforeFailedSwitch = fakeEnginePtr->unloadModelCalls;
  const int loadsBeforeFailedSwitch = fakeEnginePtr->loadModelCalls;
  qixi::NativeKataGoResult failedSwitch = linkedCore.loadEngine("b18nbt");
  expect(
    failedSwitch.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "linked core surfaces adapter load failure while switching engines"
  );
  expect(
    fakeEnginePtr->unloadModelCalls == unloadsBeforeFailedSwitch + 1 &&
      fakeEnginePtr->loadModelCalls == loadsBeforeFailedSwitch + 1,
    "adapter load failure occurs only after the old model has been unloaded"
  );
  qixi::NativeKataGoResult analysisAfterFailedSwitch = linkedCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
  expect(
    analysisAfterFailedSwitch.ok(),
    "analysis after a failed engine switch returns a safe no-engine response"
  );
  expect(
    analysisAfterFailedSwitch.responseJSON.find(R"("engine":"none")") != std::string::npos,
    "failed engine switch clears the previous loaded engine"
  );
  expect(
    fakeEnginePtr->analyzeCalls == 2,
    "analysis after a failed engine switch must not call the stale adapter model"
  );

  qixi::NativeKataGoResult badLinkedRequest = linkedCore.analyzeRequestJSON(
    R"({"moves":[{"color":"B","pass":true,"x":3,"y":3}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})"
  );
  expect(
    badLinkedRequest.code == qixi::NativeKataGoStatusCode::invalidRequest,
    "pass move with coordinates is rejected before reaching the adapter"
  );
  expect(fakeEnginePtr->analyzeCalls == 2, "malformed native analysis request does not call the adapter");

  auto expectMalformedAdapterResponseIsRejected = [](const std::string& responseJSON, const std::string& context) {
    auto malformedEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* malformedEnginePtr = malformedEngine.get();
    malformedEnginePtr->responseJSON = responseJSON;
    qixi::NativeKataGoCore malformedCore(std::move(malformedEngine));
    expect(malformedCore.configureModel(b6Config()).ok(), context + ": valid b6 model config is accepted");
    expect(malformedCore.loadEngine("b6").ok(), context + ": fake adapter loads");
    qixi::NativeKataGoResult malformedAnalysis = malformedCore.analyzeRequestJSON(emptyAnalysisRequestJSON());
    expect(
      malformedAnalysis.code == qixi::NativeKataGoStatusCode::invalidRequest,
      context + ": malformed adapter analysis response is rejected"
    );
    expect(
      malformedAnalysis.message.find("malformed analysis response") != std::string::npos,
      context + ": malformed adapter analysis response explains the adapter contract failure"
    );
    expect(malformedEnginePtr->analyzeCalls == 1, context + ": malformed adapter is still called exactly once");
  };

  expectMalformedAdapterResponseIsRejected(
    R"({"engine":"fake-native"})",
    "missing required analysis fields"
  );
  expectMalformedAdapterResponseIsRejected(
    fakeAnalysisResponseJSON("1.2"),
    "root winrate outside [0,1]"
  );
  expectMalformedAdapterResponseIsRejected(
    fakeAnalysisResponseJSON(
      "0.52",
      R"([{"x":19,"y":3,"visits":1,"winrate":0.5,"scoreMean":0.0}])"
    ),
    "move coordinates outside the board"
  );
  expectMalformedAdapterResponseIsRejected(
    fakeAnalysisResponseJSON("0.52", "[]", "[]"),
    "loaded native ownership array must not be empty"
  );
  expectMalformedAdapterResponseIsRejected(
    fakeAnalysisResponseJSON("0.52", "[]", "[0.0]"),
    "loaded native ownership array must be full board sized"
  );
  expectMalformedAdapterResponseIsRejected(
    fakeAnalysisResponseJSON("0.52", "[]", fullOwnershipJSON(), "b18nbt"),
    "stale adapter engine id must match the loaded engine"
  );

  auto expectMalformedRequestIsRejected = [](const std::string& requestJSON, const std::string& context) {
    auto requestEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* requestEnginePtr = requestEngine.get();
    qixi::NativeKataGoCore requestCore(std::move(requestEngine));
    expect(requestCore.configureModel(b6Config()).ok(), context + ": valid b6 model config is accepted");
    expect(requestCore.loadEngine("b6").ok(), context + ": fake adapter loads");
    qixi::NativeKataGoResult badRequest = requestCore.analyzeRequestJSON(requestJSON);
    expect(
      badRequest.code == qixi::NativeKataGoStatusCode::invalidRequest,
      context + ": malformed native analysis request is rejected"
    );
    expect(
      badRequest.message.find("analysis request JSON is malformed") != std::string::npos,
      context + ": malformed native analysis request explains the request contract failure"
    );
    expect(requestEnginePtr->analyzeCalls == 0, context + ": malformed native analysis request does not call adapter");
  };

  auto expectWellFormedRequestIsAccepted = [](const std::string& requestJSON, const std::string& context) {
    auto requestEngine = std::make_unique<FakeNativeKataGoEngine>();
    FakeNativeKataGoEngine* requestEnginePtr = requestEngine.get();
    qixi::NativeKataGoCore requestCore(std::move(requestEngine));
    expect(requestCore.configureModel(b6Config()).ok(), context + ": valid b6 model config is accepted");
    expect(requestCore.loadEngine("b6").ok(), context + ": fake adapter loads");
    qixi::NativeKataGoResult request = requestCore.analyzeRequestJSON(requestJSON);
    expect(request.ok(), context + ": well-formed native analysis request is accepted");
    expect(requestEnginePtr->analyzeCalls == 1, context + ": well-formed native analysis request reaches adapter");
    expect(
      requestEnginePtr->lastRequest.moves.size() >= 2 &&
        requestEnginePtr->lastRequest.moves.front().x == requestEnginePtr->lastRequest.moves.back().x &&
        requestEnginePtr->lastRequest.moves.front().y == requestEnginePtr->lastRequest.moves.back().y,
      context + ": repeated coordinates are preserved in the parsed adapter request"
    );
  };

  expectWellFormedRequestIsAccepted(
    legalRepeatedCoordinateAfterCaptureRequestJSON(),
    "repeated board coordinates after captures"
  );

  expectMalformedRequestIsRejected(
    R"({"moves":[],"komi":7.5,"rootNoise":0.0})",
    "missing maxVisits"
  );
  expectMalformedRequestIsRejected(
    R"({"moves":[],"maxVisits":0,"komi":7.5,"rootNoise":0.0})",
    "maxVisits below one"
  );
  expectMalformedRequestIsRejected(
    R"({"moves":[],"maxVisits":200001,"komi":7.5,"rootNoise":0.0})",
    "maxVisits above native cap"
  );
  expectMalformedRequestIsRejected(
    R"({"moves":[{"color":"C","x":3,"y":3}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})",
    "move color must be black or white"
  );
  expectMalformedRequestIsRejected(
    R"({"moves":[{"color":"B","pass":true,"x":3,"y":3}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})",
    "pass move must not include coordinates"
  );
  expectMalformedRequestIsRejected(
    R"({"moves":[{"color":"B","x":3}],"maxVisits":1,"komi":7.5,"rootNoise":0.0})",
    "board move must include both coordinates"
  );
  expectMalformedRequestIsRejected(
    emptyUnsupportedRulesRequestJSON(),
    "unsupported rules must be rejected"
  );
  expectMalformedRequestIsRejected(
    occupiedPointIllegalRequestJSON(),
    "board history must not play on an occupied point"
  );
  expectMalformedRequestIsRejected(
    suicideIllegalRequestJSON(),
    "board history must not contain suicide"
  );
  expectMalformedRequestIsRejected(
    simpleKoIllegalRequestJSON(),
    "board history must not immediately recapture a simple ko"
  );
  expectMalformedRequestIsRejected(
    R"({"moves":[],"maxVisits":1,"komi":151.0,"rootNoise":0.0})",
    "komi outside native range"
  );
  expectMalformedRequestIsRejected(
    R"({"moves":[],"maxVisits":1,"komi":7.5,"rootNoise":-0.01})",
    "root noise must be nonnegative"
  );

  std::cout << "Native KataGo core smoke passed" << std::endl;
  return 0;
}
