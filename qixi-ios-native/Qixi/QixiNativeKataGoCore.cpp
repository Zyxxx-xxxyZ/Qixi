#include "QixiNativeKataGoCore.hpp"

#ifndef QIXI_ENABLE_NATIVE_KATAGO
#define QIXI_ENABLE_NATIVE_KATAGO 0
#endif

#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <dirent.h>
#include <fstream>
#include <iomanip>
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

#if QIXI_ENABLE_NATIVE_KATAGO
constexpr const char* kNativeKataGoUnavailableMessage =
  "Native KataGo adapter is unexpectedly unavailable.";
#else
constexpr const char* kNativeKataGoUnavailableMessage =
  "Native KataGo is not linked into this build.";
#endif

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

bool parseJSONUnsignedInteger(
  const std::string& json,
  size_t start,
  size_t end,
  uint64_t maximum,
  uint64_t& value
) {
  if(start >= end || !isJSONDigit(json[start]))
    return false;
  if(json[start] == '0' && end != start + 1)
    return false;
  uint64_t parsed = 0;
  for(size_t offset = start; offset < end; ++offset) {
    if(!isJSONDigit(json[offset]))
      return false;
    const uint64_t digit = static_cast<uint64_t>(json[offset] - '0');
    if(parsed > (maximum - digit) / 10)
      return false;
    parsed = parsed * 10 + digit;
  }
  value = parsed;
  return true;
}

bool parseJSONStringValue(
  const std::string& json,
  size_t start,
  size_t end,
  std::string& value
) {
  size_t stringEnd = 0;
  if(!skipJSONString(json, start, stringEnd) || stringEnd != end)
    return false;
  value.clear();
  for(size_t offset = start + 1; offset + 1 < end; ++offset) {
    const char c = json[offset];
    if(c != '\\') {
      value.push_back(c);
      continue;
    }
    offset += 1;
    if(offset + 1 >= end)
      return false;
    switch(json[offset]) {
    case '"': value.push_back('"'); break;
    case '\\': value.push_back('\\'); break;
    case '/': value.push_back('/'); break;
    case 'b': value.push_back('\b'); break;
    case 'f': value.push_back('\f'); break;
    case 'n': value.push_back('\n'); break;
    case 'r': value.push_back('\r'); break;
    case 't': value.push_back('\t'); break;
    case 'u':
      // Qixi-owned request fields are ASCII. Preserve unsupported escapes as '?' instead
      // of accepting a malformed JSON string silently.
      if(offset + 4 >= end)
        return false;
      for(size_t i = offset + 1; i <= offset + 4; ++i) {
        if(!isJSONHexDigit(json[i]))
          return false;
      }
      value.push_back('?');
      offset += 4;
      break;
    default:
      return false;
    }
  }
  return true;
}

bool optionalUnsignedIntegerField(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  uint64_t maximum,
  uint64_t& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  if(!findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd))
    return true;
  return parseJSONUnsignedInteger(json, valueStart, valueEnd, maximum, value);
}

bool requiredUnsignedIntegerField(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  uint64_t maximum,
  uint64_t& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  return findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) &&
    parseJSONUnsignedInteger(json, valueStart, valueEnd, maximum, value);
}

bool optionalNumberField(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  double& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  if(!findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd))
    return true;
  return parseJSONFiniteNumber(json, valueStart, valueEnd, value);
}

bool optionalBooleanField(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  bool& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  if(!findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd))
    return true;
  return valueIsJSONBool(json, valueStart, valueEnd, value);
}

bool optionalStringField(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  std::string& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  if(!findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd))
    return true;
  return parseJSONStringValue(json, valueStart, valueEnd, value);
}

bool requiredStringField(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& key,
  std::string& value
) {
  size_t valueStart = 0;
  size_t valueEnd = 0;
  return findObjectKeyValue(json, objectStart, objectEnd, key, valueStart, valueEnd) &&
    parseJSONStringValue(json, valueStart, valueEnd, value);
}

std::string jsonEscaped(const std::string& value) {
  std::string escaped;
  escaped.reserve(value.size() + 2);
  for(char c : value) {
    switch(c) {
    case '"': escaped += "\\\""; break;
    case '\\': escaped += "\\\\"; break;
    case '\b': escaped += "\\b"; break;
    case '\f': escaped += "\\f"; break;
    case '\n': escaped += "\\n"; break;
    case '\r': escaped += "\\r"; break;
    case '\t': escaped += "\\t"; break;
    default:
      if(static_cast<unsigned char>(c) < 0x20)
        escaped += "?";
      else
        escaped.push_back(c);
      break;
    }
  }
  return escaped;
}

const char* coreEngineStateName(core::EngineState state) {
  switch(state) {
  case core::EngineState::none: return "none";
  case core::EngineState::loading: return "loading";
  case core::EngineState::ready: return "ready";
  case core::EngineState::offline: return "offline";
  case core::EngineState::unloading: return "unloading";
  }
  return "offline";
}

const char* coreStoreStateName(core::StoreState state) {
  switch(state) {
  case core::StoreState::empty: return "empty";
  case core::StoreState::loading: return "loading";
  case core::StoreState::ready: return "ready";
  case core::StoreState::saving: return "saving";
  case core::StoreState::corrupted: return "corrupted";
  }
  return "corrupted";
}

bool parseCoreModelId(const std::string& value, core::ModelId& modelId) {
  modelId = core::modelIdFromString(value);
  return value == "none" || modelId != core::ModelId::none;
}

bool parseCoreColor(const std::string& value, core::Color& color) {
  if(value == "black" || value == "B" || value == "b") {
    color = core::Color::black;
    return true;
  }
  if(value == "white" || value == "W" || value == "w") {
    color = core::Color::white;
    return true;
  }
  return false;
}

bool parseRequestSetupStonesArray(
  const std::string& json,
  size_t arrayStart,
  size_t arrayEnd,
  std::vector<NativeKataGoMove>& setupStones
);

bool parseCoreRootRef(
  const std::string& json,
  size_t objectStart,
  size_t objectEnd,
  const std::string& kindKey,
  const std::string& valueKey,
  const std::string& legacyNodeKey,
  core::RootRef& reference
) {
  std::string kind = "node";
  if(!optionalStringField(json, objectStart, objectEnd, kindKey, kind))
    return false;
  size_t valueStart = 0;
  size_t valueEnd = 0;
  const bool hasValue = findObjectKeyValue(json, objectStart, objectEnd, valueKey, valueStart, valueEnd);
  uint64_t value = 0;
  if(hasValue) {
    if(!requiredUnsignedIntegerField(
         json, objectStart, objectEnd, valueKey, std::numeric_limits<uint64_t>::max(), value
       ))
      return false;
  }
  else {
    if(legacyNodeKey.empty() ||
       !requiredUnsignedIntegerField(
         json, objectStart, objectEnd, legacyNodeKey, std::numeric_limits<uint32_t>::max(), value
       ))
      return false;
    kind = "node";
  }
  if(kind == "node") {
    if(value > std::numeric_limits<uint32_t>::max())
      return false;
    reference = core::RootRef::nodeRef(static_cast<core::NodeId>(value));
    return true;
  }
  if(kind == "intent") {
    reference = core::RootRef::intentRef(static_cast<core::UiIntentId>(value));
    return true;
  }
  if(kind == "lineage") {
    reference = core::RootRef::lineageRef(value);
    return true;
  }
  return false;
}

bool rootPayloadObject(
  const std::string& json,
  size_t rootStart,
  size_t rootEnd,
  size_t& payloadStart,
  size_t& payloadEnd
) {
  if(!findObjectKeyValue(json, rootStart, rootEnd, "payload", payloadStart, payloadEnd)) {
    payloadStart = rootStart;
    payloadEnd = rootStart;
    return true;
  }
  size_t objectEnd = 0;
  return skipJSONObject(json, payloadStart, objectEnd) && objectEnd == payloadEnd;
}

NativeKataGoResult parseCoreFrontendRequestJSON(
  const std::string& requestJSON,
  core::RequestKind& kind,
  core::RequestPayload& payload,
  core::BackendEpoch& expectedEpoch
) {
  size_t rootEnd = 0;
  if(!skipJSONObject(requestJSON, 0, rootEnd) ||
     skipJSONWhitespace(requestJSON, rootEnd) != requestJSON.size())
    return invalidRequestResult("Core request must be one JSON object.");

  std::string kindString;
  if(!requiredStringField(requestJSON, 0, rootEnd, "kind", kindString))
    return invalidRequestResult("Core request kind must be a string.");

  uint64_t epoch = 0;
  if(!optionalUnsignedIntegerField(
       requestJSON, 0, rootEnd, "expectedBackendEpoch", std::numeric_limits<uint64_t>::max(), epoch
     ))
    return invalidRequestResult("Core request expectedBackendEpoch must be an unsigned integer.");
  expectedEpoch = static_cast<core::BackendEpoch>(epoch);

  size_t payloadStart = 0;
  size_t payloadEnd = 0;
  if(!rootPayloadObject(requestJSON, 0, rootEnd, payloadStart, payloadEnd))
    return invalidRequestResult("Core request payload must be an object when present.");
  const bool hasPayload = payloadEnd > payloadStart;

  if(kindString == "boot") {
    core::BootRequest body;
    if(hasPayload &&
       (!optionalBooleanField(requestJSON, payloadStart, payloadEnd, "loadLastState", body.loadLastState) ||
        !optionalBooleanField(requestJSON, payloadStart, payloadEnd, "firstLaunch", body.firstLaunch)))
      return invalidRequestResult("Core boot payload has invalid booleans.");
    kind = core::RequestKind::boot;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "selectEngine") {
    std::string model = "none";
    if(!hasPayload || !requiredStringField(requestJSON, payloadStart, payloadEnd, "modelId", model))
      return invalidRequestResult("Core selectEngine requires payload.modelId.");
    core::SelectEngineRequest body;
    if(!parseCoreModelId(model, body.modelId))
      return invalidRequestResult("Core selectEngine modelId is unsupported.");
    kind = core::RequestKind::selectEngine;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "setKomi") {
    double komi = 7.5;
    if(!hasPayload || !optionalNumberField(requestJSON, payloadStart, payloadEnd, "komi", komi))
      return invalidRequestResult("Core setKomi requires finite payload.komi.");
    core::SetKomiRequest body;
    body.komi = static_cast<float>(komi);
    kind = core::RequestKind::setKomi;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "setWideRootNoise") {
    double noise = 0.0;
    if(!hasPayload || !optionalNumberField(requestJSON, payloadStart, payloadEnd, "noise", noise))
      return invalidRequestResult("Core setWideRootNoise requires finite payload.noise.");
    core::SetWideRootNoiseRequest body;
    body.noise = static_cast<float>(std::max(0.0, noise));
    kind = core::RequestKind::setWideRootNoise;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "newGame") {
    core::NewGameRequest body;
    double komi = body.rules.komi;
    std::string nextPla = "black";
    if(hasPayload) {
      if(!optionalNumberField(requestJSON, payloadStart, payloadEnd, "komi", komi) ||
         !optionalStringField(requestJSON, payloadStart, payloadEnd, "nextPla", nextPla))
        return invalidRequestResult("Core newGame payload is invalid.");
    }
    body.rules.komi = static_cast<float>(komi);
    if(!parseCoreColor(nextPla, body.nextPla))
      return invalidRequestResult("Core newGame nextPla is invalid.");
    kind = core::RequestKind::newGame;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "playMove") {
    if(!hasPayload)
      return invalidRequestResult("Core playMove requires a payload.");
    core::PlayMoveRequest body;
    uint64_t move = core::kMovePass;
    uint64_t uiIntentId = 0;
    if(!requiredUnsignedIntegerField(requestJSON, payloadStart, payloadEnd, "move", core::kMovePass, move) ||
       !optionalUnsignedIntegerField(requestJSON, payloadStart, payloadEnd, "uiIntentId", std::numeric_limits<uint64_t>::max(), uiIntentId) ||
       !parseCoreRootRef(
         requestJSON,
         payloadStart,
         payloadEnd,
         "parentRootKind",
         "parentRootValue",
         "parentRootId",
         body.parentRootRef
       ))
      return invalidRequestResult("Core playMove payload fields are invalid.");
    body.move = static_cast<core::Move>(move);
    body.uiIntentId = static_cast<core::UiIntentId>(uiIntentId);
    kind = core::RequestKind::playMove;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "undo" || kindString == "redo") {
    core::StepRequest body;
    uint64_t steps = 1;
    if(hasPayload &&
       !optionalUnsignedIntegerField(requestJSON, payloadStart, payloadEnd, "steps", 512, steps))
      return invalidRequestResult("Core step payload.steps is invalid.");
    body.steps = static_cast<uint32_t>(steps);
    kind = kindString == "undo" ? core::RequestKind::undo : core::RequestKind::redo;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "jumpToNode" || kindString == "jumpToLinePoint") {
    if(!hasPayload)
      return invalidRequestResult("Core jump request requires a payload.");
    core::JumpToNodeRequest body;
    if(!parseCoreRootRef(
         requestJSON,
         payloadStart,
         payloadEnd,
         "targetRootKind",
         "targetRootValue",
         "node",
         body.targetRootRef
       ))
      return invalidRequestResult("Core jump payload.node is invalid.");
    kind = kindString == "jumpToNode" ? core::RequestKind::jumpToNode : core::RequestKind::jumpToLinePoint;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "setTerritoryMode") {
    core::SetTerritoryModeRequest body;
    if(hasPayload && !optionalBooleanField(requestJSON, payloadStart, payloadEnd, "enabled", body.enabled))
      return invalidRequestResult("Core setTerritoryMode payload.enabled is invalid.");
    kind = core::RequestKind::setTerritoryMode;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "exportAnalysisState" || kindString == "importAnalysisState") {
    std::string path;
    if(!hasPayload || !requiredStringField(requestJSON, payloadStart, payloadEnd, "path", path) || path.empty())
      return invalidRequestResult("Core state import/export requires payload.path.");
    if(kindString == "exportAnalysisState") {
      core::ExportAnalysisStateRequest body;
      body.path = path;
      kind = core::RequestKind::exportAnalysisState;
      payload = body;
    }
    else {
      core::ImportAnalysisStateRequest body;
      body.path = path;
      kind = core::RequestKind::importAnalysisState;
      payload = body;
    }
    return okResult("core request parsed");
  }
  if(kindString == "enterBackground") {
    core::EnterBackgroundRequest body;
    uint64_t deadlineMs = 0;
    if(hasPayload &&
       !optionalUnsignedIntegerField(requestJSON, payloadStart, payloadEnd, "deadlineMs", std::numeric_limits<uint32_t>::max(), deadlineMs))
      return invalidRequestResult("Core enterBackground payload.deadlineMs is invalid.");
    body.deadlineMs = static_cast<uint32_t>(deadlineMs);
    kind = core::RequestKind::enterBackground;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "enterForeground") {
    kind = core::RequestKind::enterForeground;
    payload = core::EnterForegroundRequest{};
    return okResult("core request parsed");
  }
  if(kindString == "autosaveTick") {
    core::AutosaveTickRequest body;
    if(hasPayload && !optionalStringField(requestJSON, payloadStart, payloadEnd, "reason", body.reason))
      return invalidRequestResult("Core autosaveTick payload.reason is invalid.");
    kind = core::RequestKind::autosaveTick;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "relieveMemoryPressure") {
    core::RelieveMemoryPressureRequest body;
    uint64_t level = 1;
    if(hasPayload &&
       !optionalUnsignedIntegerField(requestJSON, payloadStart, payloadEnd, "level", 255, level))
      return invalidRequestResult("Core relieveMemoryPressure payload.level is invalid.");
    if(level > 1)
      return invalidRequestResult("Core relieveMemoryPressure level must be 0 (soft) or 1 (hard).");
    body.level = static_cast<uint8_t>(level);
    kind = core::RequestKind::relieveMemoryPressure;
    payload = body;
    return okResult("core request parsed");
  }
  if(kindString == "applyRecognizedBoard") {
    if(!hasPayload)
      return invalidRequestResult("Core applyRecognizedBoard requires a payload.");
    std::string nextPlaText = "black";
    if(!optionalStringField(requestJSON, payloadStart, payloadEnd, "nextPla", nextPlaText))
      return invalidRequestResult("Core applyRecognizedBoard nextPla is invalid.");
    core::Color nextPla = core::Color::black;
    if(!parseCoreColor(nextPlaText, nextPla))
      return invalidRequestResult("Core applyRecognizedBoard nextPla is invalid.");
    size_t setupStart = 0;
    size_t setupEnd = 0;
    if(!findObjectKeyValue(requestJSON, payloadStart, payloadEnd, "setupStones", setupStart, setupEnd))
      return invalidRequestResult("Core applyRecognizedBoard requires setupStones.");
    std::vector<NativeKataGoMove> setupStones;
    if(!parseRequestSetupStonesArray(requestJSON, setupStart, setupEnd, setupStones))
      return invalidRequestResult("Core applyRecognizedBoard setupStones are invalid.");
    core::ApplyRecognizedBoardRequest body;
    body.board = core::BoardLogic::emptyBoard(nextPla);
    std::array<uint8_t, core::kBoardArea> occupied{};
    for(const NativeKataGoMove& stone : setupStones) {
      const core::Move move = core::pointToMove(stone.x, stone.y);
      if(occupied[move])
        return invalidRequestResult("Core applyRecognizedBoard contains duplicate setup points.");
      occupied[move] = 1;
      body.board.cells[move] = stone.color == NativeKataGoMoveColor::black
        ? core::Color::black
        : core::Color::white;
    }
    body.board.boardHashHistory.assign(1, core::BoardLogic::boardHash(body.board));
    body.board.situationHashHistory.assign(1, core::BoardLogic::situationHash(body.board));
    body.sideToMove = nextPla;
    kind = core::RequestKind::applyRecognizedBoard;
    payload = std::move(body);
    return okResult("core request parsed");
  }
  return invalidRequestResult("Core request kind is unsupported: " + kindString);
}

void appendMoveFieldsJSON(std::ostream& out, core::Move move) {
  out << "\"move\":" << static_cast<uint32_t>(move);
  if(move == core::kMovePass) {
    out << ",\"pass\":true,\"x\":-1,\"y\":-1";
    return;
  }
  const core::Point point = core::moveToPoint(move);
  out << ",\"pass\":false,\"x\":" << point.x << ",\"y\":" << point.y;
}

void appendCoreSnapshotJSON(std::ostream& out, const core::RootSnapshot& snapshot) {
  out << "{";
  out << "\"root\":" << snapshot.root;
  out << ",\"rootLineageHash\":" << snapshot.rootLineageHash;
  out << ",\"rootVisits\":" << snapshot.rootVisits;
  out << ",\"rootWinrate\":" << snapshot.rootWinrate;
  out << ",\"rootScoreMean\":" << snapshot.rootScoreMean;
  out << ",\"hasOwnership\":" << (snapshot.hasOwnership ? "true" : "false");
  out << ",\"candidates\":[";
  for(size_t i = 0; i < snapshot.candidates.size(); ++i) {
    if(i > 0)
      out << ",";
    const auto& candidate = snapshot.candidates[i];
    out << "{";
    appendMoveFieldsJSON(out, candidate.move);
    out << ",\"visits\":" << candidate.visits;
    out << ",\"prior\":" << candidate.prior;
    out << ",\"winrate\":" << candidate.winrate;
    out << ",\"scoreMean\":" << candidate.scoreMean;
    out << ",\"utility\":" << candidate.utility;
    out << "}";
  }
  out << "],\"visibleTree\":[";
  for(size_t i = 0; i < snapshot.visibleTree.size(); ++i) {
    if(i > 0)
      out << ",";
    const auto& node = snapshot.visibleTree[i];
    out << "{";
    out << "\"id\":" << node.id;
    out << ",\"lineageHash\":" << node.lineageHash;
    if(node.parent == core::kInvalidNode)
      out << ",\"parent\":null";
    else
      out << ",\"parent\":" << node.parent;
    out << ",\"moveFromParent\":" << static_cast<uint32_t>(node.moveFromParent);
    out << ",\"moveColor\":\"";
    if(node.movePla == core::Color::black)
      out << "black";
    else if(node.movePla == core::Color::white)
      out << "white";
    else
      out << "none";
    out << "\"";
    out << ",\"ply\":" << node.ply;
    out << ",\"visits\":" << node.visits;
    out << ",\"winrate\":" << node.winrate;
    out << ",\"scoreMean\":" << node.scoreMean;
    out << ",\"analyzed\":" << (node.analyzed ? "true" : "false");
    if(node.hasQualityDelta)
      out << ",\"qualityDeltaPercent\":" << node.qualityDeltaPercent;
    else
      out << ",\"qualityDeltaPercent\":null";
    out << "}";
  }
  out << "]";
  out << ",\"ownership\":[";
  if(snapshot.hasOwnership) {
    for(size_t i = 0; i < snapshot.ownership.size(); ++i) {
      if(i > 0)
        out << ",";
      out << snapshot.ownership[i];
    }
  }
  out << "]}";
}

std::string coreBackendResultJSON(const core::BackendResult& result) {
  std::ostringstream out;
  out << std::setprecision(9);
  out << "{";
  out << "\"requestId\":" << result.requestId;
  out << ",\"backendEpoch\":" << result.backendEpoch;
  out << ",\"revision\":" << result.revision;
  out << ",\"ok\":" << (result.ok ? "true" : "false");
  out << ",\"message\":\"" << jsonEscaped(result.message) << "\"";
  out << ",\"currentRoot\":" << result.currentRoot;
  out << ",\"engineState\":\"" << coreEngineStateName(result.engineState) << "\"";
  out << ",\"storeState\":\"" << coreStoreStateName(result.storeState) << "\"";
  if(result.hasCommittedUiIntent)
    out << ",\"committedUiIntentId\":" << result.committedUiIntentId;
  else
    out << ",\"committedUiIntentId\":null";
  out << ",\"snapshot\":";
  if(result.snapshot)
    appendCoreSnapshotJSON(out, *result.snapshot);
  else
    out << "null";
  out << "}";
  return out.str();
}

std::string coreLegalMoveMaskJSON(const std::array<bool, core::kMoveCount>& mask) {
  std::ostringstream out;
  out << "{\"legal\":[";
  for(size_t i = 0; i < mask.size(); ++i) {
    if(i > 0)
      out << ",";
    out << (mask[i] ? "true" : "false");
  }
  out << "]}";
  return out.str();
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
  coreBackend.setEngineSelector(
    [this](core::ModelId modelId, core::Evaluator*& evaluator, std::string& error) {
      return selectCoreEngine(modelId, evaluator, error);
    }
  );
  coreBackend.start();
}

NativeKataGoCore::~NativeKataGoCore() {
  coreBackend.stop();
  if(engine)
    engine->unloadModel();
}

bool NativeKataGoCore::isLinked() const {
  return engine != nullptr && engine->isLinked();
}

NativeKataGoResult NativeKataGoCore::configureCoreStoreDirectory(const std::string& path) {
  std::string error;
  if(!coreBackend.setStoreDirectory(path, &error))
    return invalidRequestResult(error);
  return okResult("core store directory configured");
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
  if(engineID != "none" && !supportedEngineID(engineID))
    return invalidRequestResult("Native KataGo engine id is not supported.");
  if(engineID != "none" && modelConfigs.find(engineID) == modelConfigs.end())
    return invalidRequestResult("Native KataGo model config missing for engine.");
  if(engineID != "none" && !isLinked()) {
    return {
      NativeKataGoStatusCode::libraryNotLinked,
      kNativeKataGoUnavailableMessage,
      "",
    };
  }
  core::SelectEngineRequest payload;
  if(!parseCoreModelId(engineID, payload.modelId))
    return invalidRequestResult("Native KataGo engine id cannot be mapped to a core model id.");
  const core::BackendResult result = coreBackend.submitAndWait(
    core::RequestKind::selectEngine,
    payload,
    0
  );
  if(!result.ok)
    return invalidRequestResult(result.message);
  return {
    NativeKataGoStatusCode::ok,
    engineID == "none" ? "no engine loaded" : "Native KataGo model loaded.",
    coreBackendResultJSON(result),
  };
}

bool NativeKataGoCore::selectCoreEngine(
  core::ModelId modelId,
  core::Evaluator*& evaluator,
  std::string& error
) {
  evaluator = nullptr;
  const std::string engineID = core::modelIdToString(modelId);
  if(!engine) {
    error = "Native KataGo engine adapter is missing.";
    loadedEngineID = "none";
    return false;
  }
  const std::string previousEngineID = loadedEngineID;
  NativeKataGoModelConfig previousConfig{};
  bool hasPreviousConfig = false;
  if(previousEngineID != "none") {
    const auto previous = modelConfigs.find(previousEngineID);
    if(previous != modelConfigs.end()) {
      previousConfig = previous->second;
      hasPreviousConfig = true;
    }
  }
  const auto targetConfig = modelConfigs.find(engineID);
  if(modelId != core::ModelId::none && targetConfig == modelConfigs.end()) {
    evaluator = engine->coreEvaluator();
    error = "Native KataGo model config missing for engine.";
    return false;
  }

  auto restorePreviousModel = [&]() -> bool {
    if(!hasPreviousConfig)
      return false;
    const NativeKataGoResult restoreResult = engine->loadModel(previousConfig);
    if(!restoreResult.ok()) {
      error += "; previous model restore failed: " + restoreResult.message;
      return false;
    }
    evaluator = engine->coreEvaluator();
    if(evaluator == nullptr) {
      engine->unloadModel();
      error += "; previous model restored without a core evaluator";
      return false;
    }
    loadedEngineID = previousEngineID;
    error += "; previous model restored";
    return true;
  };

  NativeKataGoResult unloadResult = engine->unloadModel();
  if(!unloadResult.ok()) {
    error = unloadResult.message;
    evaluator = engine->coreEvaluator();
    if(evaluator == nullptr)
      loadedEngineID = "none";
    return false;
  }
  loadedEngineID = "none";
  if(modelId == core::ModelId::none)
    return true;
  NativeKataGoResult loadResult = engine->loadModel(targetConfig->second);
  if(!loadResult.ok()) {
    error = loadResult.message;
    engine->unloadModel();
    restorePreviousModel();
    return false;
  }
  evaluator = engine->coreEvaluator();
  if(evaluator == nullptr) {
    engine->unloadModel();
    error = "Native KataGo model loaded without a core evaluator.";
    restorePreviousModel();
    return false;
  }
  loadedEngineID = engineID;
  return true;
}

NativeKataGoResult NativeKataGoCore::analyzeRequestJSON(const std::string& requestJSON) {
  // Search is core::MCTSStore only. The legacy KataGo Search analyze path is disabled.
  // Callers must use submitCoreRequestJSON / latestCoreSnapshotJSON.
  (void)requestJSON;
  return invalidRequestResult(
    "Native in-process analysis uses core::MCTSStore only; "
    "analyzeRequestJSON is disabled. Use submitCoreRequest / latestCoreSnapshot."
  );
}

NativeKataGoResult NativeKataGoCore::exportTombstoneToFile(const std::string& filePath) {
  // Lifecycle "tombstones" are core::MCTSStore exports only — never KataGo Search trees.
  if(filePath.empty())
    return invalidRequestResult("Native KataGo tombstone file path must not be empty.");
  NativeKataGoResult exportPath = rejectNonRegularExistingTombstoneExportPath(filePath);
  if(!exportPath.ok())
    return exportPath;
  if(loadedEngineID == "none")
    return writeNoEngineTombstoneToFile(filePath);
  NativeKataGoResult result = exportCoreStateToFile(filePath);
  if(!result.ok())
    return result;
  NativeKataGoResult exportedFile = validateReadableNonEmptyTombstoneFile(
    filePath,
    "Core MCTS export did not produce a readable non-empty regular tombstone file.",
    "Core MCTS export produced a tombstone file exceeding the bounded size"
  );
  if(!exportedFile.ok())
    return exportedFile;
  return {
    NativeKataGoStatusCode::ok,
    "Core MCTS state exported as native tombstone.",
    result.responseJSON,
  };
}

NativeKataGoResult NativeKataGoCore::restoreTombstoneFromFile(const std::string& filePath) {
  // Lifecycle restore imports core::MCTSStore state only — never KataGo Search trees.
  if(filePath.empty())
    return invalidRequestResult("Native KataGo tombstone file path must not be empty.");
  if(loadedEngineID == "none")
    return restoreNoEngineTombstoneFromFile(filePath);
  NativeKataGoResult restoreFile = validateReadableNonEmptyTombstoneFile(
    filePath,
    "Native KataGo tombstone file is not a readable non-empty regular file.",
    "Native KataGo tombstone file exceeds the bounded restore size"
  );
  if(!restoreFile.ok()) {
    clearLoadedEngineAfterTombstoneRestoreFailure(engine.get(), loadedEngineID);
    return restoreFile;
  }
  NativeKataGoResult result = importCoreStateFromFile(filePath);
  if(!result.ok())
    clearLoadedEngineAfterTombstoneRestoreFailure(engine.get(), loadedEngineID);
  return result.ok()
    ? NativeKataGoResult{
        NativeKataGoStatusCode::ok,
        "Core MCTS state restored from native tombstone.",
        result.responseJSON,
      }
    : result;
}

NativeKataGoResult NativeKataGoCore::submitCoreRequestLocked(
  core::RequestKind kind,
  core::RequestPayload payload,
  core::BackendEpoch expectedEpoch
) {
  const core::BackendResult result = coreBackend.submitAndWait(kind, std::move(payload), expectedEpoch);
  return {NativeKataGoStatusCode::ok, result.message, coreBackendResultJSON(result)};
}

NativeKataGoResult NativeKataGoCore::submitCoreRequestJSON(const std::string& requestJSON) {
  core::RequestKind kind = core::RequestKind::boot;
  core::RequestPayload payload = core::BootRequest{};
  core::BackendEpoch expectedEpoch = 0;
  NativeKataGoResult parseResult = parseCoreFrontendRequestJSON(requestJSON, kind, payload, expectedEpoch);
  if(!parseResult.ok())
    return parseResult;
  return submitCoreRequestLocked(kind, std::move(payload), expectedEpoch);
}

NativeKataGoResult NativeKataGoCore::latestCoreSnapshotJSON() {
  // UI poll path: light snapshot avoids shipping unbounded visibleTree over the bridge.
  const core::BackendResult result = coreBackend.latestLightSnapshot(32, 4096, true);
  return {NativeKataGoStatusCode::ok, result.message, coreBackendResultJSON(result)};
}

NativeKataGoResult NativeKataGoCore::coreIoProgressJSON() {
  const core::BackendWorker::IoProgress progress = coreBackend.currentIoProgress();
  std::ostringstream out;
  out << std::boolalpha;
  out << "{";
  out << "\"active\":" << (progress.active ? "true" : "false");
  out << ",\"phase\":\"" << progress.phase << "\"";
  out << ",\"fraction\":" << progress.fraction;
  out << ",\"bytesDone\":" << progress.bytesDone;
  out << ",\"bytesTotal\":" << progress.bytesTotal;
  out << ",\"message\":\"" << progress.message << "\"";
  out << "}";
  return {NativeKataGoStatusCode::ok, progress.active ? progress.phase : "idle", out.str()};
}

NativeKataGoResult NativeKataGoCore::legalMoveMaskJSON() {
  return {
    NativeKataGoStatusCode::ok,
    "legal move mask copied",
    coreLegalMoveMaskJSON(coreBackend.legalMoveMask()),
  };
}

NativeKataGoResult NativeKataGoCore::exportCoreStateToFile(const std::string& filePath) {
  if(filePath.empty())
    return invalidRequestResult("Core MCTS export file path must not be empty.");
  core::ExportAnalysisStateRequest payload;
  payload.path = filePath;
  const core::BackendResult result = coreBackend.submitAndWait(core::RequestKind::exportAnalysisState, payload, 0);
  if(!result.ok)
    return invalidRequestResult(result.message);
  return {NativeKataGoStatusCode::ok, result.message, coreBackendResultJSON(result)};
}

NativeKataGoResult NativeKataGoCore::importCoreStateFromFile(const std::string& filePath) {
  if(filePath.empty())
    return invalidRequestResult("Core MCTS import file path must not be empty.");
  core::ImportAnalysisStateRequest payload;
  payload.path = filePath;
  const core::BackendResult result = coreBackend.submitAndWait(core::RequestKind::importAnalysisState, payload, 0);
  if(!result.ok)
    return invalidRequestResult(result.message);
  return {NativeKataGoStatusCode::ok, result.message, coreBackendResultJSON(result)};
}

}  // namespace qixi
