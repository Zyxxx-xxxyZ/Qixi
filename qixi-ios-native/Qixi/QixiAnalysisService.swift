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

enum QixiCoreRootReference: Equatable {
  case node(UInt32)
  case intent(UInt64)
  case lineage(UInt64)

  var kind: String {
    switch self {
    case .node: return "node"
    case .intent: return "intent"
    case .lineage: return "lineage"
    }
  }

  var value: UInt64 {
    switch self {
    case .node(let id): return UInt64(id)
    case .intent(let id): return id
    case .lineage(let hash): return hash
    }
  }
}

enum QixiCoreRequest: Encodable {
  case boot(loadLastState: Bool, firstLaunch: Bool, expectedBackendEpoch: UInt64 = 0)
  case selectEngine(AnalysisEngine, expectedBackendEpoch: UInt64 = 0)
  case setKomi(Double, expectedBackendEpoch: UInt64 = 0)
  case setWideRootNoise(Double, expectedBackendEpoch: UInt64 = 0)
  case newGame(komi: Double, nextPla: StoneColor, expectedBackendEpoch: UInt64 = 0)
  case playMove(move: Int, uiIntentId: UInt64, parentRoot: QixiCoreRootReference, expectedBackendEpoch: UInt64 = 0)
  case undo(steps: Int, expectedBackendEpoch: UInt64 = 0)
  case redo(steps: Int, expectedBackendEpoch: UInt64 = 0)
  case jumpToNode(QixiCoreRootReference, expectedBackendEpoch: UInt64 = 0)
  case setTerritoryMode(Bool, expectedBackendEpoch: UInt64 = 0)
  case enterBackground(deadlineMs: UInt32, expectedBackendEpoch: UInt64 = 0)
  case enterForeground(expectedBackendEpoch: UInt64 = 0)
  case autosaveTick(reason: String, expectedBackendEpoch: UInt64 = 0)
  case exportAnalysisState(path: String, expectedBackendEpoch: UInt64 = 0)
  case importAnalysisState(path: String, expectedBackendEpoch: UInt64 = 0)
  case applyRecognizedBoard(setupStones: [BoardSetupStone], nextPla: StoneColor, expectedBackendEpoch: UInt64 = 0)

  private enum CodingKeys: String, CodingKey {
    case kind
    case expectedBackendEpoch
    case payload
  }

  private enum PayloadKeys: String, CodingKey {
    case loadLastState
    case firstLaunch
    case modelId
    case komi
    case noise
    case nextPla
    case move
    case uiIntentId
    case parentRootKind
    case parentRootValue
    case steps
    case node
    case targetRootKind
    case targetRootValue
    case enabled
    case deadlineMs
    case reason
    case path
    case setupStones
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
    switch self {
    case .boot(let loadLastState, let firstLaunch, let expectedBackendEpoch):
      try container.encode("boot", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(loadLastState, forKey: .loadLastState)
      try payload.encode(firstLaunch, forKey: .firstLaunch)
    case .selectEngine(let engine, let expectedBackendEpoch):
      try container.encode("selectEngine", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(engine.rawValue, forKey: .modelId)
    case .setKomi(let komi, let expectedBackendEpoch):
      try container.encode("setKomi", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(komi, forKey: .komi)
    case .setWideRootNoise(let noise, let expectedBackendEpoch):
      try container.encode("setWideRootNoise", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(noise, forKey: .noise)
    case .newGame(let komi, let nextPla, let expectedBackendEpoch):
      try container.encode("newGame", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(komi, forKey: .komi)
      try payload.encode(nextPla == .black ? "black" : "white", forKey: .nextPla)
    case .playMove(let move, let uiIntentId, let parentRoot, let expectedBackendEpoch):
      try container.encode("playMove", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(move, forKey: .move)
      try payload.encode(uiIntentId, forKey: .uiIntentId)
      try payload.encode(parentRoot.kind, forKey: .parentRootKind)
      try payload.encode(parentRoot.value, forKey: .parentRootValue)
    case .undo(let steps, let expectedBackendEpoch):
      try container.encode("undo", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(steps, forKey: .steps)
    case .redo(let steps, let expectedBackendEpoch):
      try container.encode("redo", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(steps, forKey: .steps)
    case .jumpToNode(let targetRoot, let expectedBackendEpoch):
      try container.encode("jumpToNode", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(targetRoot.kind, forKey: .targetRootKind)
      try payload.encode(targetRoot.value, forKey: .targetRootValue)
    case .setTerritoryMode(let enabled, let expectedBackendEpoch):
      try container.encode("setTerritoryMode", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(enabled, forKey: .enabled)
    case .enterBackground(let deadlineMs, let expectedBackendEpoch):
      try container.encode("enterBackground", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(deadlineMs, forKey: .deadlineMs)
    case .enterForeground(let expectedBackendEpoch):
      try container.encode("enterForeground", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
    case .autosaveTick(let reason, let expectedBackendEpoch):
      try container.encode("autosaveTick", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(reason, forKey: .reason)
    case .exportAnalysisState(let path, let expectedBackendEpoch):
      try container.encode("exportAnalysisState", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(path, forKey: .path)
    case .importAnalysisState(let path, let expectedBackendEpoch):
      try container.encode("importAnalysisState", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(path, forKey: .path)
    case .applyRecognizedBoard(let setupStones, let nextPla, let expectedBackendEpoch):
      try container.encode("applyRecognizedBoard", forKey: .kind)
      try container.encode(expectedBackendEpoch, forKey: .expectedBackendEpoch)
      try payload.encode(setupStones, forKey: .setupStones)
      try payload.encode(nextPla == .black ? "black" : "white", forKey: .nextPla)
    }
  }
}

extension QixiCoreRequest {
  func replacingExpectedBackendEpoch(_ epoch: UInt64) -> QixiCoreRequest {
    switch self {
    case .boot(let loadLastState, let firstLaunch, _):
      return .boot(loadLastState: loadLastState, firstLaunch: firstLaunch, expectedBackendEpoch: epoch)
    case .selectEngine(let engine, _):
      return .selectEngine(engine, expectedBackendEpoch: epoch)
    case .setKomi(let komi, _):
      return .setKomi(komi, expectedBackendEpoch: epoch)
    case .setWideRootNoise(let noise, _):
      return .setWideRootNoise(noise, expectedBackendEpoch: epoch)
    case .newGame(let komi, let nextPla, _):
      return .newGame(komi: komi, nextPla: nextPla, expectedBackendEpoch: epoch)
    case .playMove(let move, let uiIntentId, let parentRoot, _):
      return .playMove(move: move, uiIntentId: uiIntentId, parentRoot: parentRoot, expectedBackendEpoch: epoch)
    case .undo(let steps, _):
      return .undo(steps: steps, expectedBackendEpoch: epoch)
    case .redo(let steps, _):
      return .redo(steps: steps, expectedBackendEpoch: epoch)
    case .jumpToNode(let targetRoot, _):
      return .jumpToNode(targetRoot, expectedBackendEpoch: epoch)
    case .setTerritoryMode(let enabled, _):
      return .setTerritoryMode(enabled, expectedBackendEpoch: epoch)
    case .enterBackground(let deadlineMs, _):
      return .enterBackground(deadlineMs: deadlineMs, expectedBackendEpoch: epoch)
    case .enterForeground:
      return .enterForeground(expectedBackendEpoch: epoch)
    case .autosaveTick(let reason, _):
      return .autosaveTick(reason: reason, expectedBackendEpoch: epoch)
    case .exportAnalysisState(let path, _):
      return .exportAnalysisState(path: path, expectedBackendEpoch: epoch)
    case .importAnalysisState(let path, _):
      return .importAnalysisState(path: path, expectedBackendEpoch: epoch)
    case .applyRecognizedBoard(let setupStones, let nextPla, _):
      return .applyRecognizedBoard(
        setupStones: setupStones,
        nextPla: nextPla,
        expectedBackendEpoch: epoch
      )
    }
  }
}

struct QixiCoreBackendResult: Decodable {
  var requestId: UInt64
  var backendEpoch: UInt64
  var revision: UInt64
  var ok: Bool
  var message: String
  var currentRoot: UInt32
  var engineState: String
  var storeState: String
  var committedUiIntentId: UInt64?
  var snapshot: QixiCoreSnapshot?
}

struct QixiCoreSnapshot: Decodable {
  var root: UInt32
  var rootLineageHash: UInt64
  var rootVisits: UInt64
  var rootWinrate: Double
  var rootScoreMean: Double
  var hasOwnership: Bool
  var candidates: [QixiCoreCandidate]
  var visibleTree: [QixiCoreTreeNode]
  var ownership: [Double]
}

struct QixiCoreCandidate: Decodable {
  var move: Int
  var pass: Bool
  var x: Int
  var y: Int
  var visits: UInt64
  var prior: Double
  var winrate: Double
  var scoreMean: Double
  var utility: Double
}

struct QixiCoreTreeNode: Decodable {
  var id: UInt32
  var lineageHash: UInt64
  var parent: UInt32?
  var moveFromParent: Int
  var moveColor: String
  var ply: UInt32
  var visits: UInt64
  var winrate: Double
  var scoreMean: Double
  var analyzed: Bool
  var qualityDeltaPercent: Double?
}

struct QixiCoreLegalMoveMask: Decodable {
  var legal: [Bool]
}

protocol QixiCoreBackendService {
  func submitCoreRequest(_ request: QixiCoreRequest) async throws -> QixiCoreBackendResult
  func latestCoreSnapshot() async throws -> QixiCoreBackendResult
  func legalMoveMask() async throws -> QixiCoreLegalMoveMask
  func exportCoreState(to url: URL) async throws
  func importCoreState(from url: URL) async throws
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
