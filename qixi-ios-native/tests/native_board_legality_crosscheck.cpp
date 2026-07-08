#include "QixiNativeKataGoCore.hpp"

#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>

namespace {

void fail(const std::string& message) {
  std::cerr << "Native board legality crosscheck failed: " << message << std::endl;
  std::exit(1);
}

bool splitCaseLine(
  const std::string& line,
  std::string& name,
  bool& swiftLegal,
  std::string& requestJSON
) {
  const size_t firstTab = line.find('\t');
  if(firstTab == std::string::npos)
    return false;
  const size_t secondTab = line.find('\t', firstTab + 1);
  if(secondTab == std::string::npos)
    return false;
  name = line.substr(0, firstTab);
  const std::string expected = line.substr(firstTab + 1, secondTab - firstTab - 1);
  if(expected == "1") {
    swiftLegal = true;
  } else if(expected == "0") {
    swiftLegal = false;
  } else {
    return false;
  }
  requestJSON = line.substr(secondTab + 1);
  return !name.empty() && !requestJSON.empty();
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

bool hasChineseRules(const qixi::NativeKataGoRules& rules) {
  return rules.koRule == qixi::NativeKataGoKoRule::simple &&
    rules.scoringRule == qixi::NativeKataGoScoringRule::area &&
    rules.taxRule == qixi::NativeKataGoTaxRule::none &&
    !rules.multiStoneSuicideLegal &&
    !rules.hasButton &&
    rules.whiteHandicapBonusRule == qixi::NativeKataGoWhiteHandicapBonusRule::n &&
    rules.friendlyPassOk;
}

}  // namespace

int main() {
  int checked = 0;
  int legalCases = 0;
  int illegalCases = 0;
  std::string line;
  while(std::getline(std::cin, line)) {
    if(line.empty())
      continue;
    std::string name;
    bool swiftLegal = false;
    std::string requestJSON;
    if(!splitCaseLine(line, name, swiftLegal, requestJSON))
      fail("malformed generated case line: " + line);

    qixi::NativeKataGoAnalysisRequest parsed{};
    const qixi::NativeKataGoResult parseResult =
      qixi::parseNativeKataGoAnalysisRequestJSON(requestJSON, parsed);
    const bool nativeLegal = parseResult.ok();
    if(nativeLegal != swiftLegal) {
      std::ostringstream message;
      message << name << " expected Swift legal=" << (swiftLegal ? "true" : "false")
              << " but native parser legal=" << (nativeLegal ? "true" : "false")
              << " message=" << parseResult.message
              << " json=" << requestJSON;
      fail(message.str());
    }
    if(nativeLegal) {
      const std::string material = qixi::nativeKataGoPositionKeyMaterial(parsed);
      if(material.empty())
        fail(name + " produced empty native position material");
      if(!hasChineseRules(parsed.rules))
        fail(name + " should expose explicit native Chinese rules");
      if(name == "empty" || name == "single-pass") {
        if(countBoardPoints(parsed, qixi::NativeKataGoBoardPoint::black) != 0 ||
           countBoardPoints(parsed, qixi::NativeKataGoBoardPoint::white) != 0)
          fail(name + " should expose an empty native final board");
      }
      if(name == "simple-capture") {
        if(parsed.finalBoard[boardIndex(0, 0)] != qixi::NativeKataGoBoardPoint::empty ||
           parsed.finalBoard[boardIndex(1, 0)] != qixi::NativeKataGoBoardPoint::black ||
           parsed.finalBoard[boardIndex(0, 1)] != qixi::NativeKataGoBoardPoint::black ||
           countBoardPoints(parsed, qixi::NativeKataGoBoardPoint::white) != 0)
          fail(name + " should expose the captured stone as empty in native final board");
      }
      if(name == "legal-repeated-coordinate-after-capture") {
        if(parsed.finalBoard[boardIndex(1, 1)] != qixi::NativeKataGoBoardPoint::black ||
           countBoardPoints(parsed, qixi::NativeKataGoBoardPoint::black) != 5 ||
           countBoardPoints(parsed, qixi::NativeKataGoBoardPoint::white) != 0)
          fail(name + " should expose the reused coordinate as black in native final board");
      }
      legalCases += 1;
    } else {
      illegalCases += 1;
    }
    checked += 1;
  }

  if(checked < 7 || legalCases == 0 || illegalCases == 0)
    fail("crosscheck did not cover both legal and illegal board histories");
  std::cout << "Native board legality crosscheck passed" << std::endl;
  return 0;
}
