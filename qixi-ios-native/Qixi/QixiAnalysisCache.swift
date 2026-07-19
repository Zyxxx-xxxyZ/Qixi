import Foundation

/// Per-engine UI analysis cache (not the core MCTS store).
/// Keys are semantic position identities from `QixiPositionIdentity`.
@MainActor
struct QixiAnalysisCache {
  static let maxCachedPositionsPerEngine = 96

  /// Outer key = `AnalysisEngine.rawValue`; inner key = semantic cache key.
  private(set) var storage: [String: [String: QixiCachedAnalysis]] = [:]

  var isEmpty: Bool { storage.isEmpty }

  /// Full map for snapshot serialize / whole-map replace.
  var snapshotMap: [String: [String: QixiCachedAnalysis]] { storage }

  mutating func replaceAll(_ map: [String: [String: QixiCachedAnalysis]]) {
    storage = map
  }

  mutating func clear() {
    storage = [:]
  }

  func entry(engine: AnalysisEngine, cacheKey: String) -> QixiCachedAnalysis? {
    storage[engine.rawValue]?[cacheKey]
  }

  mutating func put(
    engine: AnalysisEngine,
    cacheKey: String,
    positionKey: String,
    winrate: Double,
    scoreMean: Double,
    visits: Int,
    candidates: [CandidateMove],
    territory: [TerritoryPoint],
    savedAt: Date = Date()
  ) {
    var engineCache = storage[engine.rawValue, default: [:]]
    engineCache[cacheKey] = QixiCachedAnalysis(
      savedAt: savedAt,
      positionKey: positionKey,
      winrate: winrate,
      scoreMean: scoreMean,
      visits: visits,
      candidates: candidates,
      territory: territory
    )
    if engineCache.count > Self.maxCachedPositionsPerEngine {
      let overflow = engineCache.count - Self.maxCachedPositionsPerEngine
      let keysToRemove = engineCache
        .sorted { $0.value.savedAt < $1.value.savedAt }
        .prefix(overflow)
        .map(\.key)
      for key in keysToRemove {
        engineCache.removeValue(forKey: key)
      }
    }
    storage[engine.rawValue] = engineCache
  }

  /// Memory-pressure trim: keep at most the current engine/key entry.
  mutating func trimToCurrent(engine: AnalysisEngine?, cacheKey: String?) {
    var trimmed: [String: [String: QixiCachedAnalysis]] = [:]
    if let engine, engine != .none, let cacheKey,
       let entry = storage[engine.rawValue]?[cacheKey] {
      trimmed[engine.rawValue] = [cacheKey: entry]
    }
    storage = trimmed
  }

  static func cacheKey(
    engine: AnalysisEngine,
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    komi: Double,
    rootNoise: Double,
    playoutDoublingAdvantage: Double = 0,
    rootToMove: StoneColor = .black
  ) -> String {
    QixiPositionIdentity.cacheKey(
      engine: engine,
      moves: moves,
      setupStones: setupStones,
      komi: komi,
      rootNoise: rootNoise,
      playoutDoublingAdvantage: playoutDoublingAdvantage,
      rootToMove: rootToMove
    )
  }
}
