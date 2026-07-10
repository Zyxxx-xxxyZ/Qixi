#pragma once

#include "qixi/request_pool.hpp"

#include <array>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace qixi {

enum class NativeKataGoStatusCode {
  ok = 0,
  libraryNotLinked = 1,
  invalidRequest = 2,
};

struct NativeKataGoResult {
  NativeKataGoStatusCode code;
  std::string message;
  std::string responseJSON;

  bool ok() const {
    return code == NativeKataGoStatusCode::ok;
  }
};

struct NativeKataGoModelConfig {
  std::string engineID;
  std::string resourceName;
  std::string modelPath;
  std::vector<std::string> coreMLPackagePaths;
  int minimumMemoryMB;
  int recommendedMemoryMB;
  int maximumMemoryMB;
};

enum class NativeKataGoMoveColor {
  black,
  white,
};

struct NativeKataGoMove {
  NativeKataGoMoveColor color = NativeKataGoMoveColor::black;
  bool pass = false;
  int x = -1;
  int y = -1;
};

enum class NativeKataGoBoardPoint {
  empty = 0,
  black = 1,
  white = 2,
};

enum class NativeKataGoKoRule {
  simple,
  positional,
  situational,
  spight,
};

enum class NativeKataGoScoringRule {
  area,
  territory,
};

enum class NativeKataGoTaxRule {
  none,
  seki,
  all,
};

enum class NativeKataGoWhiteHandicapBonusRule {
  zero,
  n,
  nMinusOne,
};

struct NativeKataGoRules {
  NativeKataGoKoRule koRule = NativeKataGoKoRule::simple;
  NativeKataGoScoringRule scoringRule = NativeKataGoScoringRule::area;
  NativeKataGoTaxRule taxRule = NativeKataGoTaxRule::none;
  bool multiStoneSuicideLegal = false;
  bool hasButton = false;
  NativeKataGoWhiteHandicapBonusRule whiteHandicapBonusRule = NativeKataGoWhiteHandicapBonusRule::n;
  bool friendlyPassOk = true;
};

struct NativeKataGoAnalysisRequest {
  std::array<NativeKataGoBoardPoint, 19 * 19> initialBoard{};
  std::vector<NativeKataGoMove> moves;
  std::array<NativeKataGoBoardPoint, 19 * 19> finalBoard{};
  NativeKataGoRules rules;
  NativeKataGoMoveColor nextPlayer = NativeKataGoMoveColor::black;
  int maxVisits = 0;
  double komi = 0.0;
  double rootNoise = 0.0;
};

class NativeKataGoEngine {
public:
  virtual ~NativeKataGoEngine() = default;
  virtual bool isLinked() const = 0;
  virtual NativeKataGoResult unloadModel() = 0;
  virtual NativeKataGoResult loadModel(const NativeKataGoModelConfig& config) = 0;
  virtual NativeKataGoResult analyzeRequest(const NativeKataGoAnalysisRequest& request) = 0;
  virtual NativeKataGoResult exportTombstoneToFile(const std::string& filePath) = 0;
  virtual NativeKataGoResult restoreTombstoneFromFile(const std::string& filePath) = 0;
  virtual core::Evaluator* coreEvaluator() = 0;
};

std::unique_ptr<NativeKataGoEngine> makeNativeKataGoEngine();
NativeKataGoResult parseNativeKataGoAnalysisRequestJSON(
  const std::string& requestJSON,
  NativeKataGoAnalysisRequest& request
);
NativeKataGoRules nativeKataGoChineseRules();
NativeKataGoMoveColor nativeKataGoOppositeColor(NativeKataGoMoveColor color);
const char* nativeKataGoMoveColorCode(NativeKataGoMoveColor color);
const char* nativeKataGoKoRuleCode(NativeKataGoKoRule rule);
const char* nativeKataGoScoringRuleCode(NativeKataGoScoringRule rule);
const char* nativeKataGoTaxRuleCode(NativeKataGoTaxRule rule);
const char* nativeKataGoWhiteHandicapBonusRuleCode(NativeKataGoWhiteHandicapBonusRule rule);
std::string nativeKataGoPositionKeyMaterial(const NativeKataGoAnalysisRequest& request);

class NativeKataGoCore final {
public:
  NativeKataGoCore();
  explicit NativeKataGoCore(std::unique_ptr<NativeKataGoEngine> engine);
  ~NativeKataGoCore();

  bool isLinked() const;
  NativeKataGoResult configureCoreStoreDirectory(const std::string& path);
  NativeKataGoResult configureModel(const NativeKataGoModelConfig& config);
  NativeKataGoResult loadEngine(const std::string& engineID);
  NativeKataGoResult analyzeRequestJSON(const std::string& requestJSON);
  NativeKataGoResult exportTombstoneToFile(const std::string& filePath);
  NativeKataGoResult restoreTombstoneFromFile(const std::string& filePath);
  NativeKataGoResult submitCoreRequestJSON(const std::string& requestJSON);
  NativeKataGoResult latestCoreSnapshotJSON();
  NativeKataGoResult legalMoveMaskJSON();
  NativeKataGoResult exportCoreStateToFile(const std::string& filePath);
  NativeKataGoResult importCoreStateFromFile(const std::string& filePath);

private:
  bool selectCoreEngine(core::ModelId modelId, core::Evaluator*& evaluator, std::string& error);
  NativeKataGoResult submitCoreRequestLocked(
    core::RequestKind kind,
    core::RequestPayload payload,
    core::BackendEpoch expectedEpoch
  );

  std::string loadedEngineID = "none";
  std::unique_ptr<NativeKataGoEngine> engine;
  std::unordered_map<std::string, NativeKataGoModelConfig> modelConfigs;
  core::BackendWorker coreBackend;
};

}  // namespace qixi
