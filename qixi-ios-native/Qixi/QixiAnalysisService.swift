import Foundation

enum QixiRuntimeConfig {}

enum QixiAnalysisRuntime: String, CaseIterable {
  #if !QIXI_NATIVE_RELEASE
  case httpBridge
  #endif
  case nativeInProcess
}

enum QixiAnalysisInputValidationError: Error, Equatable, LocalizedError {
  case illegalMainLine(ply: Int)
  case invalidSetupStone(index: Int)
  case invalidMaxVisits(Int)
  case invalidKomi(Double)
  case invalidRootNoise(Double)

  var errorDescription: String? {
    switch self {
    case .illegalMainLine(let ply):
      return "Analysis request has an illegal move at ply \(ply)."
    case .invalidSetupStone(let index):
      return "Analysis request has an invalid setup stone at index \(index)."
    case .invalidMaxVisits(let value):
      return "Analysis request maxVisits \(value) is outside \(QixiAnalysisLimits.minMaxVisits)...\(QixiAnalysisLimits.maxMaxVisits)."
    case .invalidKomi(let value):
      return "Analysis request komi \(value) is outside -150...150."
    case .invalidRootNoise(let value):
      return "Analysis request rootNoise \(value) must be finite and non-negative."
    }
  }
}

enum QixiAnalysisResponseValidationError: Error, Equatable, LocalizedError {
  case engineMismatch(expected: AnalysisEngine, actual: String)
  case unknownEngine(String)
  case emptyPositionKey
  case nonEmptyNoEngineAnalysis(field: String)
  case missingRootWinrate(engine: String)
  case invalidRootWinrate(engine: String, value: Double)
  case missingRootScoreMean(engine: String)
  case invalidRootScoreMean(engine: String, value: Double)
  case invalidRootVisits(engine: String, value: Int)
  case invalidMoveCoordinate(index: Int, x: Int, y: Int)
  case duplicateMoveCoordinate(index: Int, x: Int, y: Int)
  case missingMoveWinrate(index: Int)
  case invalidMoveWinrate(index: Int, value: Double)
  case invalidMoveVisits(index: Int, value: Int)
  case invalidMoveScoreMean(index: Int, value: Double)
  case invalidOwnershipCount(count: Int)
  case invalidOwnership(index: Int, value: Double)

  var errorDescription: String? {
    switch self {
    case .engineMismatch(let expected, let actual):
      return "Analysis response engine \(actual) does not match expected engine \(expected.rawValue)."
    case .unknownEngine(let engine):
      return "Analysis response engine \(engine) is not a supported Qixi engine."
    case .emptyPositionKey:
      return "Analysis response position key is empty."
    case .nonEmptyNoEngineAnalysis(let field):
      return "No-engine analysis response unexpectedly contains \(field)."
    case .missingRootWinrate(let engine):
      return "Analysis response for \(engine) is missing root winrate."
    case .invalidRootWinrate(let engine, let value):
      return "Analysis response for \(engine) has invalid root winrate \(value)."
    case .missingRootScoreMean(let engine):
      return "Analysis response for \(engine) is missing root score mean."
    case .invalidRootScoreMean(let engine, let value):
      return "Analysis response for \(engine) has invalid root score mean \(value)."
    case .invalidRootVisits(let engine, let value):
      return "Analysis response for \(engine) has invalid root visits \(value)."
    case .invalidMoveCoordinate(let index, let x, let y):
      return "Analysis response move \(index) is off board at \(x),\(y)."
    case .duplicateMoveCoordinate(let index, let x, let y):
      return "Analysis response move \(index) duplicates \(x),\(y)."
    case .missingMoveWinrate(let index):
      return "Analysis response move \(index) is missing winrate."
    case .invalidMoveWinrate(let index, let value):
      return "Analysis response move \(index) has invalid winrate \(value)."
    case .invalidMoveVisits(let index, let value):
      return "Analysis response move \(index) has invalid visits \(value)."
    case .invalidMoveScoreMean(let index, let value):
      return "Analysis response move \(index) has invalid score mean \(value)."
    case .invalidOwnershipCount(let count):
      return "Analysis response ownership count \(count) is neither empty nor 19x19."
    case .invalidOwnership(let index, let value):
      return "Analysis response ownership \(index) has invalid value \(value)."
    }
  }
}

enum QixiAnalysisInputValidator {
  static func validate(moves: [BoardMove], setupStones: [BoardSetupStone] = []) throws {
    if let invalidSetupIndex = QixiBoardPosition.firstInvalidSetupStoneIndex(in: setupStones) {
      throw QixiAnalysisInputValidationError.invalidSetupStone(index: invalidSetupIndex)
    }
    if let illegalIndex = QixiBoardPosition.firstIllegalMoveIndex(in: moves, setupStones: setupStones) {
      throw QixiAnalysisInputValidationError.illegalMainLine(ply: illegalIndex + 1)
    }
  }

  static func validate(
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) throws {
    try validate(moves: moves, setupStones: setupStones)
    guard QixiAnalysisLimits.isValidMaxVisits(maxVisits) else {
      throw QixiAnalysisInputValidationError.invalidMaxVisits(maxVisits)
    }
    guard QixiAnalysisLimits.isValidKomi(komi) else {
      throw QixiAnalysisInputValidationError.invalidKomi(komi)
    }
    guard QixiAnalysisLimits.isValidRootNoise(rootNoise) else {
      throw QixiAnalysisInputValidationError.invalidRootNoise(rootNoise)
    }
  }
}

enum QixiAnalysisResponseValidator {
  static func validate(_ response: AnalysisResponse, expectedEngine: AnalysisEngine? = nil) throws {
    if let expectedEngine, !engine(response.engine, matches: expectedEngine) {
      throw QixiAnalysisResponseValidationError.engineMismatch(
        expected: expectedEngine,
        actual: response.engine
      )
    }
    guard !response.positionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw QixiAnalysisResponseValidationError.emptyPositionKey
    }

    if response.engine == AnalysisEngine.none.rawValue {
      if response.winrate != nil {
        throw QixiAnalysisResponseValidationError.nonEmptyNoEngineAnalysis(field: "winrate")
      }
      if response.scoreMean != nil {
        throw QixiAnalysisResponseValidationError.nonEmptyNoEngineAnalysis(field: "scoreMean")
      }
      if !response.moves.isEmpty {
        throw QixiAnalysisResponseValidationError.nonEmptyNoEngineAnalysis(field: "moves")
      }
      if !response.ownership.isEmpty {
        throw QixiAnalysisResponseValidationError.nonEmptyNoEngineAnalysis(field: "ownership")
      }
      if let visits = response.visits, visits < 0 {
        throw QixiAnalysisResponseValidationError.invalidRootVisits(engine: response.engine, value: visits)
      }
      return
    }

    guard let rootWinrate = response.winrate else {
      throw QixiAnalysisResponseValidationError.missingRootWinrate(engine: response.engine)
    }
    guard rootWinrate.isFinite && rootWinrate >= 0.0 && rootWinrate <= 1.0 else {
      throw QixiAnalysisResponseValidationError.invalidRootWinrate(engine: response.engine, value: rootWinrate)
    }
    guard let rootScoreMean = response.scoreMean else {
      throw QixiAnalysisResponseValidationError.missingRootScoreMean(engine: response.engine)
    }
    guard rootScoreMean.isFinite else {
      throw QixiAnalysisResponseValidationError.invalidRootScoreMean(engine: response.engine, value: rootScoreMean)
    }
    if let visits = response.visits, visits < 0 {
      throw QixiAnalysisResponseValidationError.invalidRootVisits(engine: response.engine, value: visits)
    }

    var movePoints = Set<Int>()
    for (index, move) in response.moves.enumerated() {
      guard isOnBoard(x: move.x, y: move.y) else {
        throw QixiAnalysisResponseValidationError.invalidMoveCoordinate(index: index, x: move.x, y: move.y)
      }
      guard movePoints.insert(boardIndex(x: move.x, y: move.y)).inserted else {
        throw QixiAnalysisResponseValidationError.duplicateMoveCoordinate(index: index, x: move.x, y: move.y)
      }
      guard let winrate = move.winrate else {
        throw QixiAnalysisResponseValidationError.missingMoveWinrate(index: index)
      }
      guard winrate.isFinite && winrate >= 0.0 && winrate <= 1.0 else {
        throw QixiAnalysisResponseValidationError.invalidMoveWinrate(index: index, value: winrate)
      }
      if let visits = move.visits, visits < 0 {
        throw QixiAnalysisResponseValidationError.invalidMoveVisits(index: index, value: visits)
      }
      if let scoreMean = move.scoreMean, !scoreMean.isFinite {
        throw QixiAnalysisResponseValidationError.invalidMoveScoreMean(index: index, value: scoreMean)
      }
    }

    if !response.ownership.isEmpty && response.ownership.count != QixiBoardPosition.boardSize * QixiBoardPosition.boardSize {
      throw QixiAnalysisResponseValidationError.invalidOwnershipCount(count: response.ownership.count)
    }
    for (index, ownership) in response.ownership.enumerated() {
      guard ownership.isFinite && ownership >= -1.0 && ownership <= 1.0 else {
        throw QixiAnalysisResponseValidationError.invalidOwnership(index: index, value: ownership)
      }
    }
  }

  private static func engine(_ actual: String, matches expected: AnalysisEngine) -> Bool {
    if actual == expected.rawValue { return true }
    if expected != .none && actual.hasSuffix(":\(expected.rawValue)") { return true }
    return false
  }

  private static func isOnBoard(x: Int, y: Int) -> Bool {
    x >= 0 && x < QixiBoardPosition.boardSize && y >= 0 && y < QixiBoardPosition.boardSize
  }

  private static func boardIndex(x: Int, y: Int) -> Int {
    y * QixiBoardPosition.boardSize + x
  }
}

protocol QixiAnalysisService {
  var runtime: QixiAnalysisRuntime { get }

  func setEngine(_ engine: AnalysisEngine) async throws -> BackendStatusResponse

  func analyze(
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse
}

extension QixiAnalysisService {
  func analyze(
    moves: [BoardMove],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse {
    try await analyze(
      moves: moves,
      setupStones: [],
      maxVisits: maxVisits,
      komi: komi,
      rootNoise: rootNoise
    )
  }
}

protocol QixiEngineTombstoneService {
  func exportEngineTombstone(to url: URL) async throws
  func restoreEngineTombstone(from url: URL, for engine: AnalysisEngine) async throws
}

extension QixiRuntimeConfig {
  #if QIXI_NATIVE_RELEASE
  static func analysisRuntime(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    bundle: Bundle = .main
  ) -> QixiAnalysisRuntime {
    .nativeInProcess
  }
  #else
  static let analysisRuntimeDefaultsKey = "qixi.analysisRuntime"
  static let analysisRuntimeEnvironmentKey = "QIXI_ANALYSIS_RUNTIME"
  static let analysisRuntimeInfoPlistKey = "QixiAnalysisRuntime"
  static let defaultAnalysisRuntime = QixiAnalysisRuntime.httpBridge

  static func analysisRuntime(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    bundle: Bundle = .main
  ) -> QixiAnalysisRuntime {
    if let value = environment[analysisRuntimeEnvironmentKey], let runtime = normalizedRuntime(value) {
      return runtime
    }
    if let value = defaults.string(forKey: analysisRuntimeDefaultsKey), let runtime = normalizedRuntime(value) {
      return runtime
    }
    if let value = bundle.object(forInfoDictionaryKey: analysisRuntimeInfoPlistKey) as? String,
       let runtime = normalizedRuntime(value) {
      return runtime
    }
    return defaultAnalysisRuntime
  }

  private static func normalizedRuntime(_ rawValue: String) -> QixiAnalysisRuntime? {
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: " ", with: "")
    switch normalized {
    case "http", "httpbridge", "machosted", "machostedhttp":
      return .httpBridge
    case "native", "nativeinprocess", "inprocess", "ipadnative":
      return .nativeInProcess
    default:
      return nil
    }
  }
  #endif
}

enum QixiAnalysisServiceFactory {
  static func makeDefaultService() -> any QixiAnalysisService {
    makeService(runtime: QixiRuntimeConfig.analysisRuntime())
  }

  static func makeService(runtime: QixiAnalysisRuntime) -> any QixiAnalysisService {
    switch runtime {
    #if !QIXI_NATIVE_RELEASE
    case .httpBridge:
      return HTTPBridgeAnalysisService()
    #endif
    case .nativeInProcess:
      return NativeKataGoAnalysisService()
    }
  }
}
