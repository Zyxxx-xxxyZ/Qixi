#include "qixi/core_types.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>

namespace qixi::core {

int32_t komiToKey(float komi) {
  if(!std::isfinite(komi))
    return 0;
  const double scaled = std::round(static_cast<double>(komi) * 1000.0);
  return static_cast<int32_t>(std::clamp(
    scaled,
    static_cast<double>(std::numeric_limits<int32_t>::min()),
    static_cast<double>(std::numeric_limits<int32_t>::max())
  ));
}

int32_t wideRootNoiseToKey(float noise) {
  if(!std::isfinite(noise))
    return 0;
  const double scaled = std::round(static_cast<double>(noise) * 10000.0);
  return static_cast<int32_t>(std::clamp(
    scaled,
    static_cast<double>(std::numeric_limits<int32_t>::min()),
    static_cast<double>(std::numeric_limits<int32_t>::max())
  ));
}

int32_t playoutDoublingAdvantageToKey(float pda) {
  if(!std::isfinite(pda))
    return 0;
  const double scaled = std::round(static_cast<double>(pda) * 1000.0);
  return static_cast<int32_t>(std::clamp(
    scaled,
    static_cast<double>(std::numeric_limits<int32_t>::min()),
    static_cast<double>(std::numeric_limits<int32_t>::max())
  ));
}

uint64_t hashRules(const Rules& rules) {
  uint64_t h = 1469598103934665603ULL;
  auto mix = [&](uint64_t v) {
    h ^= v;
    h *= 1099511628211ULL;
  };
  mix(static_cast<uint64_t>(rules.koRule));
  mix(static_cast<uint64_t>(rules.scoringRule));
  mix(static_cast<uint64_t>(rules.taxRule));
  mix(rules.multiStoneSuicideLegal ? 1ULL : 0ULL);
  mix(rules.hasButton ? 1ULL : 0ULL);
  mix(static_cast<uint64_t>(rules.whiteHandicapBonusRule));
  mix(rules.friendlyPassOk ? 1ULL : 0ULL);
  mix(static_cast<uint32_t>(komiToKey(rules.komi)));
  return h;
}

std::string modelIdToString(ModelId modelId) {
  switch(modelId) {
  case ModelId::none: return "none";
  case ModelId::b6: return "b6";
  case ModelId::b18nbt: return "b18nbt";
  case ModelId::b28nbt: return "b28nbt";
  }
  return "none";
}

ModelId modelIdFromString(const std::string& value) {
  if(value == "b6")
    return ModelId::b6;
  if(value == "b18nbt")
    return ModelId::b18nbt;
  if(value == "b28nbt")
    return ModelId::b28nbt;
  return ModelId::none;
}

} // namespace qixi::core
