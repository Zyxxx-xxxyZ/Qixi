#include "QixiNativeKataGoCore.hpp"

#include <array>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <dirent.h>
#include <fstream>
#include <iterator>
#include <limits>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <utility>

namespace qixi {
namespace {

constexpr size_t kNativeKataGoMaxTombstoneFileBytes = 256ULL * 1024ULL * 1024ULL;
constexpr size_t kNativeKataGoFileReadChunkBytes = 64ULL * 1024ULL;

NativeKataGoResult okResult(const std::string& message) {
  return {NativeKataGoStatusCode::ok, message, ""};
}

NativeKataGoResult invalidRequestResult(const std::string& message) {
  return {NativeKataGoStatusCode::invalidRequest, message, ""};
}

NativeKataGoRules chineseRules() {
  return {
    NativeKataGoKoRule::simple,
    NativeKataGoScoringRule::area,
    NativeKataGoTaxRule::none,
    false,
    false,
    NativeKataGoWhiteHandicapBonusRule::n,
    true,
  };
}

bool supportedEngineID(const std::string& engineID) {
  return engineID == "b6" || engineID == "b18nbt" || engineID == "b28nbt";
}

bool endsWith(const std::string& value, const std::string& suffix) {
  return value.size() >= suffix.size() &&
    value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool isJSONWhitespace(char value) {
  return value == ' ' || value == '\n' || value == '\r' || value == '\t';
}

size_t skipJSONWhitespace(const std::string& json, size_t offset) {
  while(offset < json.size() && isJSONWhitespace(json[offset]))
    offset += 1;
  return offset;
}

bool isJSONDigit(char value) {
  return value >= '0' && value <= '9';
}

bool isJSONHexDigit(char value) {
  return (value >= '0' && value <= '9') ||
    (value >= 'a' && value <= 'f') ||
    (value >= 'A' && value <= 'F');
}

bool skipJSONString(const std::string& json, size_t offset, size_t& end) {
  if(offset >= json.size() || json[offset] != '"')
    return false;
  offset += 1;
  while(offset < json.size()) {
    const unsigned char value = static_cast<unsigned char>(json[offset]);
    if(value < 0x20)
      return false;
    if(json[offset] == '"') {
      end = offset + 1;
      return true;
    }
    if(json[offset] == '\\') {
      offset += 1;
      if(offset >= json.size())
        return false;
      const char escaped = json[offset];
      if(escaped == 'u') {
        if(offset + 4 >= json.size())
          return false;
        for(size_t i = offset + 1; i <= offset + 4; ++i) {
          if(!isJSONHexDigit(json[i]))
            return false;
        }
        offset += 5;
        continue;
      }
      if(escaped != '"' && escaped != '\\' && escaped != '/' &&
         escaped != 'b' && escaped != 'f' && escaped != 'n' &&
         escaped != 'r' && escaped != 't')
        return false;
    }
    offset += 1;
  }
  return false;
}

bool skipJSONNumber(const std::string& json, size_t offset, size_t& end) {
  if(offset >= json.size())
    return false;
  if(json[offset] == '-')
    offset += 1;
  if(offset >= json.size())
    return false;
  if(json[offset] == '0') {
    offset += 1;
  }
  else if(json[offset] >= '1' && json[offset] <= '9') {
    while(offset < json.size() && isJSONDigit(json[offset]))
      offset += 1;
  }
  else {
    return false;
  }
  if(offset < json.size() && json[offset] == '.') {
    offset += 1;
    if(offset >= json.size() || !isJSONDigit(json[offset]))
      return false;
    while(offset < json.size() && isJSONDigit(json[offset]))
      offset += 1;
  }
  if(offset < json.size() && (json[offset] == 'e' || json[offset] == 'E')) {
    offset += 1;
    if(offset < json.size() && (json[offset] == '+' || json[offset] == '-'))
      offset += 1;
    if(offset >= json.size() || !isJSONDigit(json[offset]))
      return false;
    while(offset < json.size() && isJSONDigit(json[offset]))
      offset += 1;
  }
  end = offset;
  return true;
}

bool skipJSONValue(const std::string& json, size_t offset, size_t& end);

bool skipJSONObject(const std::string& json, size_t offset, size_t& end) {
  offset = skipJSONWhitespace(json, offset);
  if(offset >= json.size() || json[offset] != '{')
    return false;
  offset = skipJSONWhitespace(json, offset + 1);
  if(offset < json.size() && json[offset] == '}') {
    end = offset + 1;
    return true;
  }
  while(offset < json.size()) {
    size_t keyEnd = 0;
    if(!skipJSONString(json, offset, keyEnd))
      return false;
    offset = skipJSONWhitespace(json, keyEnd);
    if(offset >= json.size() || json[offset] != ':')
      return false;
    offset = skipJSONWhitespace(json, offset + 1);
    if(!skipJSONValue(json, offset, offset))
      return false;
    offset = skipJSONWhitespace(json, offset);
    if(offset < json.size() && json[offset] == ',') {
      offset = skipJSONWhitespace(json, offset + 1);
      continue;
    }
    if(offset < json.size() && json[offset] == '}') {
      end = offset + 1;
      return true;
    }
    return false;
  }
  return false;
}

bool skipJSONArray(const std::string& json, size_t offset, size_t& end) {
  offset = skipJSONWhitespace(json, offset);
  if(offset >= json.size() || json[offset] != '[')
    return false;
  offset = skipJSONWhitespace(json, offset + 1);
  if(offset < json.size() && json[offset] == ']') {
    end = offset + 1;
    return true;
  }
  while(offset < json.size()) {
    if(!skipJSONValue(json, offset, offset))
      return false;
    offset = skipJSONWhitespace(json, offset);
    if(offset < json.size() && json[offset] == ',') {
      offset = skipJSONWhitespace(json, offset + 1);
      continue;
    }
    if(offset < json.size() && json[offset] == ']') {
      end = offset + 1;
      return true;
    }
    return false;
  }
  return false;
}

bool skipJSONLiteral(const std::string& json, size_t offset, const std::string& literal, size_t& end) {
  if(json.compare(offset, literal.size(), literal) != 0)
    return false;
  end = offset + literal.size();
  return true;
}

bool skipJSONValue(const std::string& json, size_t offset, size_t& end) {
  offset = skipJSONWhitespace(json, offset);
  if(offset >= json.size())
    return false;
  if(json[offset] == '"')
    return skipJSONString(json, offset, end);
  if(json[offset] == '{')
    return skipJSONObject(json, offset, end);
  if(json[offset] == '[')
    return skipJSONArray(json, offset, end);
  if(json[offset] == 't')
    return skipJSONLiteral(json, offset, "true", end);
  if(json[offset] == 'f')
    return skipJSONLiteral(json, offset, "false", end);
  if(json[offset] == 'n')
    return skipJSONLiteral(json, offset, "null", end);
  return skipJSONNumber(json, offset, end);
}

bool stringKeyMatches(const std::string& json, size_t keyStart, size_t keyEnd, const std::string& key) {
  return keyEnd == keyStart + key.size() + 2 &&
    json.compare(keyStart + 1, key.size(), key) == 0;
}

bool findObjectKeyValue(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  size_t& valueStart,
  size_t& valueEnd
) {
  size_t offset = skipJSONWhitespace(json, objectStart);
  if(offset >= objectEnd || json[offset] != '{')
    return false;
  offset = skipJSONWhitespace(json, offset + 1);
  while(offset < objectEnd && json[offset] != '}') {
    const size_t keyStart = offset;
    size_t keyEnd = 0;
    if(!skipJSONString(json, offset, keyEnd))
      return false;
    offset = skipJSONWhitespace(json, keyEnd);
    if(offset >= objectEnd || json[offset] != ':')
      return false;
    offset = skipJSONWhitespace(json, offset + 1);
    const size_t currentValueStart = offset;
    size_t currentValueEnd = 0;
    if(!skipJSONValue(json, currentValueStart, currentValueEnd) || currentValueEnd > objectEnd)
      return false;
    if(stringKeyMatches(json, keyStart, keyEnd, key)) {
      valueStart = currentValueStart;
      valueEnd = currentValueEnd;
      return true;
    }
    offset = skipJSONWhitespace(json, currentValueEnd);
    if(offset < objectEnd && json[offset] == ',')
      offset = skipJSONWhitespace(json, offset + 1);
    else if(offset < objectEnd && json[offset] != '}')
      return false;
  }
  return false;
}

bool valueIsJSONString(const std::string& json, size_t start, size_t end, bool requireNonEmpty) {
  size_t stringEnd = 0;
  if(!skipJSONString(json, start, stringEnd) || stringEnd != end)
    return false;
  return !requireNonEmpty || end > start + 2;
}

bool parseJSONFiniteNumber(const std::string& json, size_t start, size_t end, double& value) {
  size_t numberEnd = 0;
  if(!skipJSONNumber(json, start, numberEnd) || numberEnd != end)
    return false;
  errno = 0;
  const std::string text = json.substr(start, end - start);
  char* parsedEnd = nullptr;
  value = std::strtod(text.c_str(), &parsedEnd);
  return errno == 0 && parsedEnd == text.c_str() + text.size() && std::isfinite(value);
}

bool parseJSONNonNegativeInteger(const std::string& json, size_t start, size_t end, int maximum, int& value) {
  if(start >= end || !isJSONDigit(json[start]))
    return false;
  if(json[start] == '0' && end != start + 1)
    return false;
  int parsed = 0;
  for(size_t offset = start; offset < end; ++offset) {
    if(!isJSONDigit(json[offset]))
      return false;
    const int digit = json[offset] - '0';
    if(parsed > (maximum - digit) / 10)
      return false;
    parsed = parsed * 10 + digit;
  }
  value = parsed;
  return true;
}

bool valueIsJSONStringEqual(const std::string& json, size_t start, size_t end, const std::string& expected) {
  return end == start + expected.size() + 2 &&
    start < json.size() &&
    json[start] == '"' &&
    json.compare(start + 1, expected.size(), expected) == 0 &&
    json[end - 1] == '"';
}

bool valueIsJSONBool(const std::string& json, size_t start, size_t end, bool& value) {
  if(end == start + 4 && json.compare(start, 4, "true") == 0) {
    value = true;
    return true;
  }
  if(end == start + 5 && json.compare(start, 5, "false") == 0) {
    value = false;
    return true;
  }
  return false;
}

bool requiredStringFieldLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  return findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) &&
    valueIsJSONString(json, valueStart, valueEnd, true);
}

bool requiredStringFieldEquals(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  const std::string& expected
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  return findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) &&
    valueIsJSONStringEqual(json, valueStart, valueEnd, expected);
}

bool requiredIntegerFieldInRangeLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  int minimum,
  int maximum,
  int& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  if(!findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) ||
     !parseJSONNonNegativeInteger(json, valueStart, valueEnd, maximum, value))
    return false;
  return value >= minimum;
}

bool requiredIntegerFieldLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  int maximum,
  int& value
) {
  return requiredIntegerFieldInRangeLooksValid(json, objectStart, objectEnd, key, 0, maximum, value);
}

bool requiredNumberFieldInRangeLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  double minimum,
  double maximum,
  double& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  return findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) &&
    parseJSONFiniteNumber(json, valueStart, valueEnd, value) &&
    value >= minimum && value <= maximum;
}

bool requiredNumberFieldInRangeLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  double minimum,
  double maximum
) {
  double value = 0.0;
  return requiredNumberFieldInRangeLooksValid(json, objectStart, objectEnd, key, minimum, maximum, value);
}

bool requiredFiniteNumberFieldLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  double value = 0.0;
  return findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) &&
    parseJSONFiniteNumber(json, valueStart, valueEnd, value);
}

bool requiredNumberFieldAtLeastLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  double minimum,
  double& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  return findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) &&
    parseJSONFiniteNumber(json, valueStart, valueEnd, value) &&
    value >= minimum;
}

bool optionalStringFieldLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  if(!findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd))
    return true;
  return valueIsJSONString(json, valueStart, valueEnd, false);
}

bool optionalBooleanFieldLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  bool& present,
  bool& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  present = findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd);
  if(!present)
    return true;
  return valueIsJSONBool(json, valueStart, valueEnd, value);
}

bool optionalIntegerFieldInRangeLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  int minimum,
  int maximum,
  bool& present,
  int& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  present = findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd);
  if(!present)
    return true;
  if(!parseJSONNonNegativeInteger(json, valueStart, valueEnd, maximum, value))
    return false;
  return value >= minimum;
}

bool validateMoveObject(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  std::array<bool, 19 * 19>& seenMoves
) {
  int x = 0;
  int y = 0;
  int visits = 0;
  if(!requiredIntegerFieldLooksValid(json, objectStart, objectEnd, "x", 18, x))
    return false;
  if(!requiredIntegerFieldLooksValid(json, objectStart, objectEnd, "y", 18, y))
    return false;
  const size_t boardIndex = static_cast<size_t>(y * 19 + x);
  if(seenMoves[boardIndex])
    return false;
  seenMoves[boardIndex] = true;
  return requiredIntegerFieldLooksValid(
      json, objectStart, objectEnd, "visits", std::numeric_limits<int>::max(), visits
    ) &&
    requiredNumberFieldInRangeLooksValid(json, objectStart, objectEnd, "winrate", 0.0, 1.0) &&
    requiredFiniteNumberFieldLooksValid(json, objectStart, objectEnd, "scoreMean") &&
    optionalStringFieldLooksValid(json, objectStart, objectEnd, "move");
}

using NativeBoardSnapshot = std::array<int, 19 * 19>;

int nativeStoneValue(NativeKataGoMoveColor color) {
  return color == NativeKataGoMoveColor::black ? 1 : 2;
}

NativeKataGoBoardPoint nativeBoardPointFromStoneValue(int stone) {
  if(stone == 1)
    return NativeKataGoBoardPoint::black;
  if(stone == 2)
    return NativeKataGoBoardPoint::white;
  return NativeKataGoBoardPoint::empty;
}

std::array<NativeKataGoBoardPoint, 19 * 19> nativeBoardPointsFromSnapshot(
  const NativeBoardSnapshot& board
) {
  std::array<NativeKataGoBoardPoint, 19 * 19> points{};
  for(size_t index = 0; index < points.size(); ++index)
    points[index] = nativeBoardPointFromStoneValue(board[index]);
  return points;
}

int nativeBoardIndex(int x, int y) {
  return y * 19 + x;
}

void nativeBoardNeighbors(int point, std::array<int, 4>& neighbors, int& count) {
  count = 0;
  const int x = point % 19;
  const int y = point / 19;
  if(x > 0)
    neighbors[count++] = point - 1;
  if(x + 1 < 19)
    neighbors[count++] = point + 1;
  if(y > 0)
    neighbors[count++] = point - 19;
  if(y + 1 < 19)
    neighbors[count++] = point + 19;
}

std::vector<int> nativeBoardGroup(const NativeBoardSnapshot& board, int start) {
  const int color = board[static_cast<size_t>(start)];
  if(color == 0)
    return {};
  std::array<bool, 19 * 19> visited{};
  std::vector<int> group;
  std::vector<int> stack;
  stack.push_back(start);
  while(!stack.empty()) {
    const int point = stack.back();
    stack.pop_back();
    if(visited[static_cast<size_t>(point)])
      continue;
    visited[static_cast<size_t>(point)] = true;
    group.push_back(point);
    std::array<int, 4> neighbors{};
    int neighborCount = 0;
    nativeBoardNeighbors(point, neighbors, neighborCount);
    for(int index = 0; index < neighborCount; ++index) {
      const int neighbor = neighbors[static_cast<size_t>(index)];
      if(board[static_cast<size_t>(neighbor)] == color && !visited[static_cast<size_t>(neighbor)])
        stack.push_back(neighbor);
    }
  }
  return group;
}

bool nativeBoardGroupHasLiberty(const NativeBoardSnapshot& board, const std::vector<int>& group) {
  for(int point : group) {
    std::array<int, 4> neighbors{};
    int neighborCount = 0;
    nativeBoardNeighbors(point, neighbors, neighborCount);
    for(int index = 0; index < neighborCount; ++index) {
      if(board[static_cast<size_t>(neighbors[static_cast<size_t>(index)])] == 0)
        return true;
    }
  }
  return false;
}

bool applyNativeBoardMove(
  const NativeBoardSnapshot& board,
  const NativeKataGoMove& move,
  NativeBoardSnapshot& nextBoard
) {
  const int point = nativeBoardIndex(move.x, move.y);
  if(board[static_cast<size_t>(point)] != 0)
    return false;
  nextBoard = board;
  const int stone = nativeStoneValue(move.color);
  const int opponent = stone == 1 ? 2 : 1;
  nextBoard[static_cast<size_t>(point)] = stone;

  std::array<int, 4> neighbors{};
  int neighborCount = 0;
  nativeBoardNeighbors(point, neighbors, neighborCount);
  for(int index = 0; index < neighborCount; ++index) {
    const int neighbor = neighbors[static_cast<size_t>(index)];
    if(nextBoard[static_cast<size_t>(neighbor)] != opponent)
      continue;
    const std::vector<int> group = nativeBoardGroup(nextBoard, neighbor);
    if(!nativeBoardGroupHasLiberty(nextBoard, group)) {
      for(int captured : group)
        nextBoard[static_cast<size_t>(captured)] = 0;
    }
  }

  const std::vector<int> ownGroup = nativeBoardGroup(nextBoard, point);
  return nativeBoardGroupHasLiberty(nextBoard, ownGroup);
}

bool nativeMoveHistoryLooksLegal(
  const NativeBoardSnapshot& initialBoard,
  const std::vector<NativeKataGoMove>& moves,
  NativeBoardSnapshot& finalBoard
) {
  NativeBoardSnapshot board = initialBoard;
  NativeBoardSnapshot boardBeforePreviousMove{};
  bool hasBoardBeforePreviousMove = false;
  for(const NativeKataGoMove& move : moves) {
    if(move.pass) {
      boardBeforePreviousMove = board;
      hasBoardBeforePreviousMove = true;
      continue;
    }
    NativeBoardSnapshot nextBoard{};
    if(!applyNativeBoardMove(board, move, nextBoard))
      return false;
    if(hasBoardBeforePreviousMove && nextBoard == boardBeforePreviousMove)
      return false;
    boardBeforePreviousMove = board;
    hasBoardBeforePreviousMove = true;
    board = nextBoard;
  }
  finalBoard = board;
  return true;
}

bool nativeSetupStonesLookLegal(
  const std::vector<NativeKataGoMove>& setupStones,
  NativeBoardSnapshot& initialBoard
) {
  NativeBoardSnapshot board{};
  std::array<bool, 19 * 19> seen{};
  for(const NativeKataGoMove& stone : setupStones) {
    if(stone.pass || stone.x < 0 || stone.x >= 19 || stone.y < 0 || stone.y >= 19)
      return false;
    const int point = nativeBoardIndex(stone.x, stone.y);
    if(seen[static_cast<size_t>(point)])
      return false;
    seen[static_cast<size_t>(point)] = true;
    board[static_cast<size_t>(point)] = nativeStoneValue(stone.color);
  }

  std::array<bool, 19 * 19> checked{};
  for(int point = 0; point < 19 * 19; ++point) {
    if(board[static_cast<size_t>(point)] == 0 || checked[static_cast<size_t>(point)])
      continue;
    const std::vector<int> group = nativeBoardGroup(board, point);
    for(int groupPoint : group)
      checked[static_cast<size_t>(groupPoint)] = true;
    if(!nativeBoardGroupHasLiberty(board, group))
      return false;
  }

  initialBoard = board;
  return true;
}

std::string requiredColorFieldCanonicalValue(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd
);

bool parseRequestMoveObject(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  NativeKataGoMove& move
) {
  const std::string color = requiredColorFieldCanonicalValue(json, objectStart, objectEnd);
  bool passPresent = false;
  bool passValue = false;
  bool xPresent = false;
  bool yPresent = false;
  int x = 0;
  int y = 0;
  if(color.empty())
    return false;
  if(!optionalBooleanFieldLooksValid(json, objectStart, objectEnd, "pass", passPresent, passValue))
    return false;
  if(!optionalIntegerFieldInRangeLooksValid(json, objectStart, objectEnd, "x", 0, 18, xPresent, x))
    return false;
  if(!optionalIntegerFieldInRangeLooksValid(json, objectStart, objectEnd, "y", 0, 18, yPresent, y))
    return false;
  move.color = color == "B" ? NativeKataGoMoveColor::black : NativeKataGoMoveColor::white;
  if(passPresent && passValue) {
    if(xPresent || yPresent)
      return false;
    move.pass = true;
    move.x = -1;
    move.y = -1;
    return true;
  }
  if(!xPresent || !yPresent)
    return false;
  move.pass = false;
  move.x = x;
  move.y = y;
  return true;
}

bool parseRequestSetupStoneObject(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  NativeKataGoMove& stone
) {
  const std::string color = requiredColorFieldCanonicalValue(json, objectStart, objectEnd);
  int x = 0;
  int y = 0;
  if(color.empty() ||
     !requiredIntegerFieldLooksValid(json, objectStart, objectEnd, "x", 18, x) ||
     !requiredIntegerFieldLooksValid(json, objectStart, objectEnd, "y", 18, y))
    return false;
  bool passPresent = false;
  bool passValue = false;
  if(!optionalBooleanFieldLooksValid(json, objectStart, objectEnd, "pass", passPresent, passValue) ||
     (passPresent && passValue))
    return false;
  stone.color = color == "B" ? NativeKataGoMoveColor::black : NativeKataGoMoveColor::white;
  stone.pass = false;
  stone.x = x;
  stone.y = y;
  return true;
}

bool parseRequestMovesArray(
  const std::string& json,
  size_t arrayStart,
  size_t arrayEnd,
  std::vector<NativeKataGoMove>& moves
) {
  moves.clear();
  size_t offset = skipJSONWhitespace(json, arrayStart);
  if(offset >= arrayEnd || json[offset] != '[')
    return false;
  offset = skipJSONWhitespace(json, offset + 1);
  if(offset < arrayEnd && json[offset] == ']')
    return offset + 1 == arrayEnd;

  while(offset < arrayEnd) {
    const size_t objectStart = offset;
    size_t objectEnd = 0;
    if(!skipJSONObject(json, objectStart, objectEnd) || objectEnd > arrayEnd)
      return false;
    NativeKataGoMove move{};
    if(!parseRequestMoveObject(json, objectStart, objectEnd, move))
      return false;
    moves.push_back(move);
    offset = skipJSONWhitespace(json, objectEnd);
    if(offset < arrayEnd && json[offset] == ',') {
      offset = skipJSONWhitespace(json, offset + 1);
      continue;
    }
    if(offset < arrayEnd && json[offset] == ']')
      return offset + 1 == arrayEnd;
    return false;
  }
  return false;
}

bool parseRequestSetupStonesArray(
  const std::string& json,
  size_t arrayStart,
  size_t arrayEnd,
  std::vector<NativeKataGoMove>& setupStones
) {
  setupStones.clear();
  size_t offset = skipJSONWhitespace(json, arrayStart);
  if(offset >= arrayEnd || json[offset] != '[')
    return false;
  offset = skipJSONWhitespace(json, offset + 1);
  if(offset < arrayEnd && json[offset] == ']')
    return offset + 1 == arrayEnd;

  while(offset < arrayEnd) {
    const size_t objectStart = offset;
    size_t objectEnd = 0;
    if(!skipJSONObject(json, objectStart, objectEnd) || objectEnd > arrayEnd)
      return false;
    NativeKataGoMove stone{};
    if(!parseRequestSetupStoneObject(json, objectStart, objectEnd, stone))
      return false;
    setupStones.push_back(stone);
    if(setupStones.size() > 19 * 19)
      return false;
    offset = skipJSONWhitespace(json, objectEnd);
    if(offset < arrayEnd && json[offset] == ',') {
      offset = skipJSONWhitespace(json, offset + 1);
      continue;
    }
    if(offset < arrayEnd && json[offset] == ']')
      return offset + 1 == arrayEnd;
    return false;
  }
  return false;
}

bool optionalNextPlayerLooksValid(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  bool& present,
  NativeKataGoMoveColor& nextPlayer
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  present = findObjectKeyValue(json, objectStart, objectEnd, "nextPlayer", valueStart, valueEnd);
  if(!present)
    return true;
  if(valueIsJSONStringEqual(json, valueStart, valueEnd, "B")) {
    nextPlayer = NativeKataGoMoveColor::black;
    return true;
  }
  if(valueIsJSONStringEqual(json, valueStart, valueEnd, "W")) {
    nextPlayer = NativeKataGoMoveColor::white;
    return true;
  }
  return false;
}

bool parseNativeAnalysisRequest(const std::string& json, NativeKataGoAnalysisRequest& request) {
  const size_t objectStart = skipJSONWhitespace(json, 0);
  size_t objectEnd = 0;
  if(!skipJSONObject(json, objectStart, objectEnd))
    return false;
  if(skipJSONWhitespace(json, objectEnd) != json.size())
    return false;

  int maxVisits = 0;
  size_t movesStart = 0;
  size_t movesEnd = 0;
  size_t setupStonesStart = 0;
  size_t setupStonesEnd = 0;
  size_t rulesStart = 0;
  size_t rulesEnd = 0;
  double komi = 0.0;
  double rootNoise = 0.0;
  std::vector<NativeKataGoMove> moves;
  std::vector<NativeKataGoMove> setupStones;
  NativeBoardSnapshot initialBoard{};
  NativeBoardSnapshot finalBoard{};
  if(!findObjectKeyValue(json, objectStart, objectEnd, "moves", movesStart, movesEnd) ||
     !parseRequestMovesArray(json, movesStart, movesEnd, moves) ||
     !requiredIntegerFieldInRangeLooksValid(json, objectStart, objectEnd, "maxVisits", 1, 200000, maxVisits) ||
     !requiredNumberFieldInRangeLooksValid(json, objectStart, objectEnd, "komi", -150.0, 150.0, komi) ||
     !requiredNumberFieldAtLeastLooksValid(json, objectStart, objectEnd, "rootNoise", 0.0, rootNoise))
    return false;
  if(findObjectKeyValue(json, objectStart, objectEnd, "rules", rulesStart, rulesEnd) &&
     !valueIsJSONStringEqual(json, rulesStart, rulesEnd, "Chinese"))
    return false;
  if(findObjectKeyValue(json, objectStart, objectEnd, "setupStones", setupStonesStart, setupStonesEnd) &&
     !parseRequestSetupStonesArray(json, setupStonesStart, setupStonesEnd, setupStones))
    return false;
  if(!nativeSetupStonesLookLegal(setupStones, initialBoard))
    return false;
  if(!nativeMoveHistoryLooksLegal(initialBoard, moves, finalBoard))
    return false;

  bool nextPlayerPresent = false;
  NativeKataGoMoveColor requestedNextPlayer = NativeKataGoMoveColor::black;
  if(!optionalNextPlayerLooksValid(json, objectStart, objectEnd, nextPlayerPresent, requestedNextPlayer))
    return false;
  request.moves = std::move(moves);
  request.initialBoard = nativeBoardPointsFromSnapshot(initialBoard);
  request.finalBoard = nativeBoardPointsFromSnapshot(finalBoard);
  request.rules = chineseRules();
  const NativeKataGoMoveColor replayNextPlayer = request.moves.empty()
    ? requestedNextPlayer
    : nativeKataGoOppositeColor(request.moves.back().color);
  if(nextPlayerPresent && replayNextPlayer != requestedNextPlayer)
    return false;
  request.nextPlayer = replayNextPlayer;
  request.maxVisits = maxVisits;
  request.komi = komi;
  request.rootNoise = rootNoise;
  return true;
}

std::string requiredColorFieldCanonicalValue(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  if(!findObjectKeyValue(json, objectStart, objectEnd, "color", valueStart, valueEnd))
    return "";
  if(valueIsJSONStringEqual(json, valueStart, valueEnd, "B"))
    return "B";
  if(valueIsJSONStringEqual(json, valueStart, valueEnd, "W"))
    return "W";
  return "";
}

bool validateMovesArray(const std::string& json, size_t arrayStart, size_t arrayEnd) {
  size_t offset = skipJSONWhitespace(json, arrayStart);
  if(offset >= arrayEnd || json[offset] != '[')
    return false;
  offset = skipJSONWhitespace(json, offset + 1);
  if(offset < arrayEnd && json[offset] == ']')
    return offset + 1 == arrayEnd;

  int moveCount = 0;
  std::array<bool, 19 * 19> seenMoves{};
  while(offset < arrayEnd) {
    const size_t objectStart = offset;
    size_t objectEnd = 0;
    if(!skipJSONObject(json, objectStart, objectEnd) || objectEnd > arrayEnd)
      return false;
    if(!validateMoveObject(json, objectStart, objectEnd, seenMoves))
      return false;
    moveCount += 1;
    if(moveCount > 19 * 19)
      return false;
    offset = skipJSONWhitespace(json, objectEnd);
    if(offset < arrayEnd && json[offset] == ',') {
      offset = skipJSONWhitespace(json, offset + 1);
      continue;
    }
    if(offset < arrayEnd && json[offset] == ']')
      return offset + 1 == arrayEnd;
    return false;
  }
  return false;
}

bool validateOwnershipArray(const std::string& json, size_t arrayStart, size_t arrayEnd) {
  size_t offset = skipJSONWhitespace(json, arrayStart);
  if(offset >= arrayEnd || json[offset] != '[')
    return false;
  offset = skipJSONWhitespace(json, offset + 1);
  if(offset < arrayEnd && json[offset] == ']')
    return false;

  int count = 0;
  while(offset < arrayEnd) {
    const size_t valueStart = offset;
    size_t valueEnd = 0;
    double value = 0.0;
    if(!skipJSONNumber(json, valueStart, valueEnd) ||
       !parseJSONFiniteNumber(json, valueStart, valueEnd, value) ||
       value < -1.0 || value > 1.0)
      return false;
    count += 1;
    if(count > 19 * 19)
      return false;
    offset = skipJSONWhitespace(json, valueEnd);
    if(offset < arrayEnd && json[offset] == ',') {
      offset = skipJSONWhitespace(json, offset + 1);
      continue;
    }
    if(offset < arrayEnd && json[offset] == ']')
      return offset + 1 == arrayEnd && count == 19 * 19;
    return false;
  }
  return false;
}

bool nativeAnalysisResponseShapeLooksValid(const std::string& json, const std::string& expectedEngineID) {
  const size_t objectStart = skipJSONWhitespace(json, 0);
  size_t objectEnd = 0;
  if(!skipJSONObject(json, objectStart, objectEnd))
    return false;
  if(skipJSONWhitespace(json, objectEnd) != json.size())
    return false;

  int visits = 0;
  if(!requiredStringFieldEquals(json, objectStart, objectEnd, "engine", expectedEngineID) ||
     !requiredStringFieldLooksValid(json, objectStart, objectEnd, "state") ||
     !requiredStringFieldLooksValid(json, objectStart, objectEnd, "positionKey") ||
     !requiredNumberFieldInRangeLooksValid(json, objectStart, objectEnd, "winrate", 0.0, 1.0) ||
     !requiredFiniteNumberFieldLooksValid(json, objectStart, objectEnd, "scoreMean") ||
     !requiredIntegerFieldLooksValid(json, objectStart, objectEnd, "visits", std::numeric_limits<int>::max(), visits))
    return false;

  size_t movesStart = 0;
  size_t movesEnd = 0;
  size_t ownershipStart = 0;
  size_t ownershipEnd = 0;
  return findObjectKeyValue(json, objectStart, objectEnd, "moves", movesStart, movesEnd) &&
    findObjectKeyValue(json, objectStart, objectEnd, "ownership", ownershipStart, ownershipEnd) &&
    validateMovesArray(json, movesStart, movesEnd) &&
    validateOwnershipArray(json, ownershipStart, ownershipEnd);
}

NativeKataGoResult validateAdapterAnalysisResult(const NativeKataGoResult& result, const std::string& expectedEngineID) {
  if(!result.ok())
    return result;
  if(!nativeAnalysisResponseShapeLooksValid(result.responseJSON, expectedEngineID))
    return invalidRequestResult("Native KataGo adapter returned malformed analysis response.");
  return result;
}

std::string stableHexDigest(const std::string& value) {
  uint64_t hash = 1469598103934665603ULL;
  for(unsigned char byte : value) {
    hash ^= byte;
    hash *= 1099511628211ULL;
  }
  const char* digits = "0123456789abcdef";
  std::string out(16, '0');
  for(int i = 15; i >= 0; --i) {
    out[i] = digits[hash & 0xF];
    hash >>= 4;
  }
  return out;
}

NativeKataGoResult noEngineAnalysisResult(const NativeKataGoAnalysisRequest& request) {
  const std::string keyMaterial = nativeKataGoPositionKeyMaterial(request);
  if(keyMaterial.empty())
    return invalidRequestResult("Native KataGo analysis request JSON cannot be canonicalized.");
  return {
    NativeKataGoStatusCode::ok,
    "no engine loaded",
    "{\"engine\":\"none\","
      "\"state\":\"no engine loaded\","
      "\"positionKey\":\"native-none:" + stableHexDigest(keyMaterial) + "\","
      "\"winrate\":null,"
      "\"scoreMean\":null,"
      "\"visits\":0,"
      "\"moves\":[],"
      "\"ownership\":[]}",
  };
}

std::string noEngineTombstoneJSON() {
  return "{\"schemaVersion\":1,"
    "\"kind\":\"qixi-native-katago-tombstone\","
    "\"engine\":\"none\","
    "\"state\":\"no engine loaded\"}";
}

bool noEngineTombstoneLooksValid(const std::string& contents) {
  size_t objectEnd = 0;
  if(!skipJSONObject(contents, 0, objectEnd))
    return false;
  if(skipJSONWhitespace(contents, objectEnd) != contents.size())
    return false;

  size_t valueStart = 0;
  size_t valueEnd = 0;
  int schemaVersion = 0;
  if(!findObjectKeyValue(contents, 0, objectEnd, "schemaVersion", valueStart, valueEnd) ||
     !parseJSONNonNegativeInteger(contents, valueStart, valueEnd, 1000, schemaVersion) ||
     schemaVersion != 1)
    return false;

  if(!findObjectKeyValue(contents, 0, objectEnd, "kind", valueStart, valueEnd) ||
     !valueIsJSONStringEqual(contents, valueStart, valueEnd, "qixi-native-katago-tombstone"))
    return false;

  if(!findObjectKeyValue(contents, 0, objectEnd, "engine", valueStart, valueEnd) ||
     !valueIsJSONStringEqual(contents, valueStart, valueEnd, "none"))
    return false;

  return findObjectKeyValue(contents, 0, objectEnd, "state", valueStart, valueEnd) &&
    valueIsJSONString(contents, valueStart, valueEnd, true);
}

bool readableNonEmptyFile(const std::string& filePath);
NativeKataGoResult validateReadableNonEmptyTombstoneFile(
  const std::string& filePath,
  const std::string& unreadableMessage,
  const std::string& oversizedMessage
);
NativeKataGoResult readTombstoneFileBounded(const std::string& filePath, std::string& contents);
bool readableNonEmptyDirectory(const std::string& directoryPath);
NativeKataGoResult rejectNonRegularExistingTombstoneExportPath(const std::string& filePath);

NativeKataGoResult writeNoEngineTombstoneToFile(const std::string& filePath) {
  NativeKataGoResult exportPath = rejectNonRegularExistingTombstoneExportPath(filePath);
  if(!exportPath.ok())
    return exportPath;
  std::ofstream out(filePath, std::ios::binary | std::ios::trunc);
  if(!out)
    return invalidRequestResult("Native KataGo tombstone file could not be opened for writing.");
  out << noEngineTombstoneJSON();
  if(!out)
    return invalidRequestResult("Native KataGo tombstone file could not be written.");
  return okResult("native no-engine tombstone exported");
}

NativeKataGoResult restoreNoEngineTombstoneFromFile(const std::string& filePath) {
  std::string contents;
  NativeKataGoResult readResult = readTombstoneFileBounded(filePath, contents);
  if(!readResult.ok())
    return readResult;
  if(!noEngineTombstoneLooksValid(contents))
    return invalidRequestResult("Native KataGo no-engine tombstone is malformed.");
  return okResult("native no-engine tombstone restored");
}

bool readableRegularFileSize(const std::string& filePath, off_t& byteCount) {
  struct stat metadata;
  if(lstat(filePath.c_str(), &metadata) != 0)
    return false;
  if(!S_ISREG(metadata.st_mode) || metadata.st_size <= 0)
    return false;
  byteCount = metadata.st_size;
  return true;
}

bool readableNonEmptyFile(const std::string& filePath) {
  off_t byteCount = 0;
  if(!readableRegularFileSize(filePath, byteCount))
    return false;
  std::ifstream in(filePath, std::ios::binary);
  return static_cast<bool>(in);
}

NativeKataGoResult validateReadableNonEmptyTombstoneFile(
  const std::string& filePath,
  const std::string& unreadableMessage,
  const std::string& oversizedMessage
) {
  off_t byteCount = 0;
  if(!readableRegularFileSize(filePath, byteCount))
    return invalidRequestResult(unreadableMessage);
  if(static_cast<uint64_t>(byteCount) > kNativeKataGoMaxTombstoneFileBytes)
    return invalidRequestResult(
      oversizedMessage + " The limit is " + std::to_string(kNativeKataGoMaxTombstoneFileBytes) + " bytes."
    );
  std::ifstream in(filePath, std::ios::binary);
  if(!in)
    return invalidRequestResult(unreadableMessage);
  return okResult("native tombstone file is readable within the bounded size limit");
}

NativeKataGoResult readTombstoneFileBounded(const std::string& filePath, std::string& contents) {
  NativeKataGoResult validation = validateReadableNonEmptyTombstoneFile(
    filePath,
    "Native KataGo tombstone file is not a readable non-empty regular file.",
    "Native KataGo tombstone file exceeds the bounded restore size"
  );
  if(!validation.ok())
    return validation;

  std::ifstream in(filePath, std::ios::binary);
  if(!in)
    return invalidRequestResult("Native KataGo tombstone file could not be opened for reading.");
  contents.clear();
  std::array<char, kNativeKataGoFileReadChunkBytes> buffer{};
  while(in) {
    in.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize count = in.gcount();
    if(count > 0) {
      if(contents.size() + static_cast<size_t>(count) > kNativeKataGoMaxTombstoneFileBytes)
        return invalidRequestResult(
          "Native KataGo tombstone file exceeds the bounded restore size. The limit is " +
          std::to_string(kNativeKataGoMaxTombstoneFileBytes) + " bytes."
        );
      contents.append(buffer.data(), static_cast<size_t>(count));
    }
  }
  if(!in.eof())
    return invalidRequestResult("Native KataGo tombstone file could not be fully read.");
  return okResult("native tombstone file read within bounded size");
}

bool readableNonEmptyDirectory(const std::string& directoryPath) {
  struct stat metadata;
  if(lstat(directoryPath.c_str(), &metadata) != 0)
    return false;
  if(!S_ISDIR(metadata.st_mode))
    return false;
  DIR* dir = opendir(directoryPath.c_str());
  if(dir == nullptr)
    return false;
  bool nonEmpty = false;
  while(dirent* entry = readdir(dir)) {
    const std::string name = entry->d_name;
    if(name != "." && name != "..") {
      nonEmpty = true;
      break;
    }
  }
  closedir(dir);
  return nonEmpty;
}

bool existingPathIsNonRegularFile(const std::string& filePath) {
  struct stat metadata;
  if(lstat(filePath.c_str(), &metadata) != 0)
    return false;
  return !S_ISREG(metadata.st_mode);
}

NativeKataGoResult rejectNonRegularExistingTombstoneExportPath(const std::string& filePath) {
  if(existingPathIsNonRegularFile(filePath))
    return invalidRequestResult("Native KataGo tombstone export path must be a regular file or a new file.");
  return okResult("native tombstone export path accepted");
}

void clearLoadedEngineAfterTombstoneRestoreFailure(
  NativeKataGoEngine* engine,
  std::string& loadedEngineID
) {
  loadedEngineID = "none";
  if(engine != nullptr)
    (void)engine->unloadModel();
}

}  // namespace

NativeKataGoResult parseNativeKataGoAnalysisRequestJSON(
  const std::string& requestJSON,
  NativeKataGoAnalysisRequest& request
) {
  if(requestJSON.empty()) {
    request = NativeKataGoAnalysisRequest{};
    return invalidRequestResult("Native KataGo analysis request JSON must not be empty.");
  }
  NativeKataGoAnalysisRequest parsed{};
  if(!parseNativeAnalysisRequest(requestJSON, parsed)) {
    request = NativeKataGoAnalysisRequest{};
    return invalidRequestResult("Native KataGo analysis request JSON is malformed.");
  }
  request = std::move(parsed);
  return okResult("native analysis request parsed");
}

NativeKataGoRules nativeKataGoChineseRules() {
  return chineseRules();
}

NativeKataGoMoveColor nativeKataGoOppositeColor(NativeKataGoMoveColor color) {
  return color == NativeKataGoMoveColor::black
    ? NativeKataGoMoveColor::white
    : NativeKataGoMoveColor::black;
}

const char* nativeKataGoMoveColorCode(NativeKataGoMoveColor color) {
  return color == NativeKataGoMoveColor::black ? "B" : "W";
}

const char* nativeKataGoKoRuleCode(NativeKataGoKoRule rule) {
  switch(rule) {
  case NativeKataGoKoRule::simple:
    return "SIMPLE";
  case NativeKataGoKoRule::positional:
    return "POSITIONAL";
  case NativeKataGoKoRule::situational:
    return "SITUATIONAL";
  case NativeKataGoKoRule::spight:
    return "SPIGHT";
  }
  return "SIMPLE";
}

const char* nativeKataGoScoringRuleCode(NativeKataGoScoringRule rule) {
  return rule == NativeKataGoScoringRule::area ? "AREA" : "TERRITORY";
}

const char* nativeKataGoTaxRuleCode(NativeKataGoTaxRule rule) {
  switch(rule) {
  case NativeKataGoTaxRule::none:
    return "NONE";
  case NativeKataGoTaxRule::seki:
    return "SEKI";
  case NativeKataGoTaxRule::all:
    return "ALL";
  }
  return "NONE";
}

const char* nativeKataGoWhiteHandicapBonusRuleCode(NativeKataGoWhiteHandicapBonusRule rule) {
  switch(rule) {
  case NativeKataGoWhiteHandicapBonusRule::zero:
    return "0";
  case NativeKataGoWhiteHandicapBonusRule::n:
    return "N";
  case NativeKataGoWhiteHandicapBonusRule::nMinusOne:
    return "N-1";
  }
  return "N";
}

std::string nativeKataGoPositionKeyMaterial(const NativeKataGoAnalysisRequest& request) {
  std::string material = "setup:";
  bool wroteSetupStone = false;
  for(size_t index = 0; index < request.initialBoard.size(); ++index) {
    const NativeKataGoBoardPoint point = request.initialBoard[index];
    if(point == NativeKataGoBoardPoint::empty)
      continue;
    if(wroteSetupStone)
      material += "|";
    wroteSetupStone = true;
    material += point == NativeKataGoBoardPoint::black ? "B" : "W";
    material += ":";
    material += std::to_string(static_cast<int>(index % 19));
    material += ",";
    material += std::to_string(static_cast<int>(index / 19));
  }
  material += "|history:";
  for(size_t index = 0; index < request.moves.size(); ++index) {
    if(index > 0)
      material += "|";
    const NativeKataGoMove& move = request.moves[index];
    material += std::to_string(index);
    material += "=";
    material += nativeKataGoMoveColorCode(move.color);
    material += ":";
    if(move.pass) {
      material += "pass";
    } else {
      material += std::to_string(move.x);
      material += ",";
      material += std::to_string(move.y);
    }
  }
  material += "|next:";
  material += nativeKataGoMoveColorCode(request.nextPlayer);
  material += "|rules:ko=";
  material += nativeKataGoKoRuleCode(request.rules.koRule);
  material += ",scoring=";
  material += nativeKataGoScoringRuleCode(request.rules.scoringRule);
  material += ",tax=";
  material += nativeKataGoTaxRuleCode(request.rules.taxRule);
  material += ",suicide=";
  material += request.rules.multiStoneSuicideLegal ? "1" : "0";
  material += ",button=";
  material += request.rules.hasButton ? "1" : "0";
  material += ",whiteHandicapBonus=";
  material += nativeKataGoWhiteHandicapBonusRuleCode(request.rules.whiteHandicapBonusRule);
  material += ",friendlyPassOk=";
  material += request.rules.friendlyPassOk ? "1" : "0";
  std::ostringstream komi;
  komi << std::hexfloat << request.komi;
  std::ostringstream rootNoise;
  rootNoise << std::hexfloat << request.rootNoise;
  material += "|komi:";
  material += komi.str();
  material += "|rootNoise:";
  material += rootNoise.str();
  return material;
}

NativeKataGoCore::NativeKataGoCore()
  : NativeKataGoCore(makeNativeKataGoEngine()) {
}

NativeKataGoCore::NativeKataGoCore(std::unique_ptr<NativeKataGoEngine> engine)
  : engine(std::move(engine)) {
}

bool NativeKataGoCore::isLinked() const {
  return engine != nullptr && engine->isLinked();
}

NativeKataGoResult NativeKataGoCore::configureModel(const NativeKataGoModelConfig& config) {
  if(!supportedEngineID(config.engineID))
    return invalidRequestResult("Native KataGo model config has unsupported engine id.");
  if(config.resourceName.empty())
    return invalidRequestResult("Native KataGo model resource name must not be empty.");
  if(config.modelPath.empty())
    return invalidRequestResult("Native KataGo model path must not be empty.");
  if(!endsWith(config.modelPath, config.resourceName))
    return invalidRequestResult("Native KataGo model path must end with the model resource name.");
  if(!readableNonEmptyFile(config.modelPath))
    return invalidRequestResult("Native KataGo model path must point to a readable non-empty file.");
  for(const std::string& coreMLPackagePath : config.coreMLPackagePaths) {
    if(coreMLPackagePath.empty())
      return invalidRequestResult("Native KataGo CoreML package path must not be empty.");
    if(!readableNonEmptyDirectory(coreMLPackagePath))
      return invalidRequestResult("Native KataGo CoreML package path must point to a readable non-empty directory.");
  }
  if(config.minimumMemoryMB <= 0 || config.recommendedMemoryMB <= 0 || config.maximumMemoryMB <= 0)
    return invalidRequestResult("Native KataGo model memory budgets must be positive.");
  if(config.minimumMemoryMB > config.recommendedMemoryMB || config.recommendedMemoryMB > config.maximumMemoryMB)
    return invalidRequestResult("Native KataGo model memory budgets must be ordered.");
  modelConfigs[config.engineID] = config;
  return okResult("native model configured");
}

NativeKataGoResult NativeKataGoCore::loadEngine(const std::string& engineID) {
  if(engineID.empty())
    return invalidRequestResult("Native KataGo engine id must not be empty.");
  if(engineID == "none") {
    loadedEngineID = "none";
    if(engine != nullptr) {
      NativeKataGoResult unloadResult = engine->unloadModel();
      if(!unloadResult.ok())
        return unloadResult;
    }
    return okResult("no engine loaded");
  }
  if(!supportedEngineID(engineID))
    return invalidRequestResult("Native KataGo engine id is not supported.");
  loadedEngineID = "none";
  if(engine == nullptr)
    return invalidRequestResult("Native KataGo engine adapter is missing.");
  NativeKataGoResult unloadResult = engine->unloadModel();
  if(!unloadResult.ok())
    return unloadResult;
  auto config = modelConfigs.find(engineID);
  if(config == modelConfigs.end())
    return invalidRequestResult("Native KataGo model config missing for engine.");
  NativeKataGoResult result = engine->loadModel(config->second);
  if(result.ok())
    loadedEngineID = engineID;
  return result;
}

NativeKataGoResult NativeKataGoCore::analyzeRequestJSON(const std::string& requestJSON) {
  NativeKataGoAnalysisRequest request{};
  NativeKataGoResult parseResult = parseNativeKataGoAnalysisRequestJSON(requestJSON, request);
  if(!parseResult.ok())
    return parseResult;
  if(loadedEngineID == "none")
    return noEngineAnalysisResult(request);
  if(engine == nullptr)
    return invalidRequestResult("Native KataGo engine adapter is missing.");
  return validateAdapterAnalysisResult(engine->analyzeRequest(request), loadedEngineID);
}

NativeKataGoResult NativeKataGoCore::exportTombstoneToFile(const std::string& filePath) {
  if(filePath.empty())
    return invalidRequestResult("Native KataGo tombstone file path must not be empty.");
  NativeKataGoResult exportPath = rejectNonRegularExistingTombstoneExportPath(filePath);
  if(!exportPath.ok())
    return exportPath;
  if(loadedEngineID == "none")
    return writeNoEngineTombstoneToFile(filePath);
  if(engine == nullptr)
    return invalidRequestResult("Native KataGo engine adapter is missing.");
  NativeKataGoResult result = engine->exportTombstoneToFile(filePath);
  if(!result.ok())
    return result;
  NativeKataGoResult exportedFile = validateReadableNonEmptyTombstoneFile(
    filePath,
    "Native KataGo adapter did not produce a readable non-empty regular tombstone file.",
    "Native KataGo adapter produced a tombstone file exceeding the bounded size"
  );
  if(!exportedFile.ok())
    return exportedFile;
  return result;
}

NativeKataGoResult NativeKataGoCore::restoreTombstoneFromFile(const std::string& filePath) {
  if(filePath.empty())
    return invalidRequestResult("Native KataGo tombstone file path must not be empty.");
  if(loadedEngineID == "none")
    return restoreNoEngineTombstoneFromFile(filePath);
  if(engine == nullptr)
    return invalidRequestResult("Native KataGo engine adapter is missing.");
  NativeKataGoResult restoreFile = validateReadableNonEmptyTombstoneFile(
    filePath,
    "Native KataGo tombstone file is not a readable non-empty regular file.",
    "Native KataGo tombstone file exceeds the bounded restore size"
  );
  if(!restoreFile.ok()) {
    clearLoadedEngineAfterTombstoneRestoreFailure(engine.get(), loadedEngineID);
    return restoreFile;
  }
  NativeKataGoResult result = engine->restoreTombstoneFromFile(filePath);
  if(!result.ok())
    clearLoadedEngineAfterTombstoneRestoreFailure(engine.get(), loadedEngineID);
  return result;
}

}  // namespace qixi
