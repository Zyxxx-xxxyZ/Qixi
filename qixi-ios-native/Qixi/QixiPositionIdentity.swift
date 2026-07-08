import Foundation

enum QixiPositionIdentity {
  static let fixedRules = QixiRules.fixedRules

  static func cacheKey(
    engine: AnalysisEngine,
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    komi: Double,
    rootNoise: Double
  ) -> String {
    let normalizedSetupStones = canonicalSetupStones(setupStones)
    var key = "\(engine.rawValue)|rules:\(fixedRules)|komiBits:\(doubleBits(komi))|rootNoiseBits:\(doubleBits(rootNoise))|"
    if !normalizedSetupStones.isEmpty {
      key.append("setup:")
      key.append(canonicalSetupText(normalizedSetupStones))
      key.append("|next:")
      key.append(QixiBoardPosition.nextPlayer(after: moves).rawValue)
      key.append("|")
    }
    key.append("history:")
    key.reserveCapacity(key.count + moves.count * 16)
    for (index, move) in moves.enumerated() {
      if index > 0 {
        key.append(";")
      }
      if move.isPass {
        key.append("\(index):\(move.color.rawValue):pass")
      } else {
        key.append("\(index):\(move.color.rawValue):\(move.x ?? -1):\(move.y ?? -1)")
      }
    }
    return key
  }

  private static func canonicalSetupStones(_ setupStones: [BoardSetupStone]) -> [BoardSetupStone] {
    var bestByPoint: [Int: BoardSetupStone] = [:]
    for stone in setupStones where stone.x >= 0 && stone.x < 19 && stone.y >= 0 && stone.y < 19 {
      bestByPoint[stone.id] = stone
    }
    return bestByPoint.values.sorted {
      if $0.y != $1.y { return $0.y < $1.y }
      if $0.x != $1.x { return $0.x < $1.x }
      return $0.color.rawValue < $1.color.rawValue
    }
  }

  private static func canonicalSetupText(_ setupStones: [BoardSetupStone]) -> String {
    var text = ""
    text.reserveCapacity(setupStones.count * 8)
    for (index, stone) in setupStones.enumerated() {
      if index > 0 {
        text.append(";")
      }
      text.append("\(stone.color.rawValue):\(stone.x):\(stone.y)")
    }
    return text
  }

  private static func doubleBits(_ value: Double) -> String {
    String(value.bitPattern, radix: 16)
  }
}

struct QixiAnalysisRequestIdentity: Equatable {
  var engine: AnalysisEngine
  var cacheKey: String

  init(
    engine: AnalysisEngine,
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    komi: Double,
    rootNoise: Double
  ) {
    self.engine = engine
    self.cacheKey = QixiPositionIdentity.cacheKey(
      engine: engine,
      moves: moves,
      setupStones: setupStones,
      komi: komi,
      rootNoise: rootNoise
    )
  }

  func matches(
    engine: AnalysisEngine,
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    komi: Double,
    rootNoise: Double
  ) -> Bool {
    self == QixiAnalysisRequestIdentity(
      engine: engine,
      moves: moves,
      setupStones: setupStones,
      komi: komi,
      rootNoise: rootNoise
    )
  }
}
