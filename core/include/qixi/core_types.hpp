#pragma once

#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace qixi::core {

constexpr int kBoardLen = 19;
constexpr int kBoardArea = kBoardLen * kBoardLen;
constexpr int kMovePass = kBoardArea;
constexpr int kMoveCount = kBoardArea + 1;
constexpr int kMaxNNHistory = 5;
constexpr int kOwnershipDim = kBoardArea;
constexpr uint32_t kInvalidNode = std::numeric_limits<uint32_t>::max();
constexpr uint32_t kInvalidAction = std::numeric_limits<uint32_t>::max();
constexpr uint32_t kSearchThreadCount = 1;
// v4: per-node minVisitedRootDepth + stored raw NN leaf (persistent visit semantics).
constexpr uint32_t kPersistVersion = 4;
constexpr uint32_t kMinimumReadablePersistVersion = 2;
// Sentinel: node has never been visited by any root under the min-depth criterion.
constexpr uint32_t kNeverVisitedRootDepth = std::numeric_limits<uint32_t>::max();
// Fixed map: absolute node ply/depth → node on the current selection path.
// Go plies stay well below this; 2048 is the requested hard cap.
constexpr size_t kSearchChainDepthMapLen = 2048;
constexpr uint64_t kPersistMagic = 0x514958494D435453ULL; // "QIXIMCTS"

using NodeId = uint32_t;
using ActionId = uint32_t;
using Move = uint16_t;
using VisitCount = uint64_t;
using RequestId = uint64_t;
using RequestSeq = uint64_t;
using UiIntentId = uint64_t;
using BackendEpoch = uint64_t;
using Revision = uint64_t;
using GameId = uint64_t;

enum class Color : uint8_t {
  empty = 0,
  black = 1,
  white = 2,
};

enum class ModelId : uint8_t {
  none = 0,
  b6 = 1,
  b18nbt = 2,
  b28nbt = 3,
};

enum class EngineState : uint8_t {
  none = 0,
  loading = 1,
  ready = 2,
  offline = 3,
  unloading = 4,
};

enum class StoreState : uint8_t {
  empty = 0,
  loading = 1,
  ready = 2,
  saving = 3,
  corrupted = 4,
};

enum class SearchState : uint8_t {
  stopped = 0,
  running = 1,
  stoppingAtBoundary = 2,
  failed = 3,
};

enum class KoRule : uint8_t {
  simple = 0,
  positional = 1,
  situational = 2,
};

enum class ScoringRule : uint8_t {
  area = 0,
  territory = 1,
};

enum class TaxRule : uint8_t {
  none = 0,
  seki = 1,
  all = 2,
};

enum class WhiteHandicapBonusRule : uint8_t {
  zero = 0,
  n = 1,
  nMinusOne = 2,
};

struct Rules {
  KoRule koRule = KoRule::simple;
  ScoringRule scoringRule = ScoringRule::area;
  TaxRule taxRule = TaxRule::none;
  bool multiStoneSuicideLegal = false;
  bool hasButton = false;
  WhiteHandicapBonusRule whiteHandicapBonusRule = WhiteHandicapBonusRule::n;
  bool friendlyPassOk = true;
  float komi = 7.5f;
};

struct AnalysisKey {
  GameId gameId = 0;
  ModelId modelId = ModelId::none;
  uint64_t rulesHash = 0;
  int32_t komiKey = 7500;
  int32_t wideRootNoiseKey = 0;

  bool operator==(const AnalysisKey& other) const {
    return gameId == other.gameId &&
      modelId == other.modelId &&
      rulesHash == other.rulesHash &&
      komiKey == other.komiKey &&
      wideRootNoiseKey == other.wideRootNoiseKey;
  }
};

struct RootRef {
  enum class Kind : uint8_t {
    node = 0,
    uiIntent = 1,
    lineage = 2,
  };

  Kind kind = Kind::node;
  uint64_t value = 0;

  static RootRef nodeRef(NodeId id) {
    return {Kind::node, id};
  }

  static RootRef intentRef(UiIntentId id) {
    return {Kind::uiIntent, id};
  }

  static RootRef lineageRef(uint64_t hash) {
    return {Kind::lineage, hash};
  }
};

struct Point {
  int x = -1;
  int y = -1;
};

inline Color opposite(Color color) {
  if(color == Color::black)
    return Color::white;
  if(color == Color::white)
    return Color::black;
  return Color::empty;
}

inline bool isBoardMove(Move move) {
  return move < kBoardArea;
}

inline Move pointToMove(int x, int y) {
  return static_cast<Move>(y * kBoardLen + x);
}

inline Point moveToPoint(Move move) {
  if(move == kMovePass)
    return {-1, -1};
  return {static_cast<int>(move % kBoardLen), static_cast<int>(move / kBoardLen)};
}

int32_t komiToKey(float komi);
int32_t wideRootNoiseToKey(float noise);
uint64_t hashRules(const Rules& rules);
std::string modelIdToString(ModelId modelId);
ModelId modelIdFromString(const std::string& value);

} // namespace qixi::core
