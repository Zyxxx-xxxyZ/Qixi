import Foundation

func fullOwnershipJSON(_ value: String = "0.0") -> String {
  "[\(Array(repeating: value, count: 19 * 19).joined(separator: ","))]"
}

func backendStatusJSON() -> Data {
  Data(
    """
    {"engine":"none","engineId":null,"state":"fake backend ready","running":true,"paused":false}
    """.utf8
  )
}

func loadedNativeAnalysisResponseJSON(
  positionKey: String = "adapter-stale-position-key",
  winrate: String = "0.52",
  scoreMean: String = "1.25",
  visits: String = "1",
  movesJSON: String = "[]",
  ownershipJSON: String = fullOwnershipJSON()
) -> String {
  """
  {"engine":"b6","state":"fake native analysis","positionKey":"\(positionKey)","winrate":\(winrate),"scoreMean":\(scoreMean),"visits":\(visits),"moves":\(movesJSON),"ownership":\(ownershipJSON)}
  """
}

func noEngineNativeAnalysisResponseJSON() -> String {
  """
  {"engine":"none","state":"no engine loaded","positionKey":"fake-native-none","winrate":null,"scoreMean":null,"visits":0,"moves":[],"ownership":[]}
  """
}

func installerArtifactRegularFileNames(in directory: URL, fileManager: FileManager = .default) throws -> [String] {
  try fileManager.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsSubdirectoryDescendants]
  )
  .filter { url in
    let name = url.lastPathComponent
    guard name.hasSuffix(".tmp") || name.hasSuffix(".backup") || name.hasSuffix(".receipt-backup") else {
      return false
    }
    return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
  }
  .map(\.lastPathComponent)
}

func coreMLPackageArtifactNames(in directory: URL, fileManager: FileManager = .default) throws -> [String] {
  try fileManager.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
    options: [.skipsSubdirectoryDescendants]
  )
  .filter { url in
    let name = url.lastPathComponent
    guard name.hasSuffix(".coreml-package-tmp") ||
      name.hasSuffix(".coreml-package-backup") ||
      name.hasSuffix(".coreml-package-receipt-backup") else {
      return false
    }
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
    return values?.isSymbolicLink != true && (values?.isDirectory == true || values?.isRegularFile == true)
  }
  .map(\.lastPathComponent)
}

final class FakeSwitchNativeKataGoBridge: NativeKataGoBridgeProtocol {
  var isLinked: Bool { true }
  var analysisResponseJSON = noEngineNativeAnalysisResponseJSON()
  var restoreError: Error?
  var engineIDToFailOnLoad: String?
  private(set) var configuredEngineIDs: [String] = []
  private(set) var configuredCoreMLPackagePaths: [[String]] = []
  private(set) var loadedEngineIDs: [String] = []
  private(set) var analysisRequestJSONs: [String] = []
  private(set) var exportedTombstoneURLs: [URL] = []
  private(set) var restoredTombstoneURLs: [URL] = []

  func configureModel(
    _ engineID: String,
    resourceName: String,
    modelPath: String,
    coreMLPackagePaths: [String],
    minimumMemoryMB: Int32,
    recommendedMemoryMB: Int32,
    maximumMemoryMB: Int32
  ) throws {
    configuredEngineIDs.append(engineID)
    configuredCoreMLPackagePaths.append(coreMLPackagePaths)
  }

  func loadEngine(_ engineID: String) throws {
    loadedEngineIDs.append(engineID)
    if engineID == engineIDToFailOnLoad {
      throw NSError(
        domain: "QixiNativeKataGo",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "fake load failure for \(engineID)"]
      )
    }
  }

  func analyzeRequestJSON(_ requestJSON: String) throws -> String {
    analysisRequestJSONs.append(requestJSON)
    return analysisResponseJSON
  }

  func exportTombstone(to url: URL) throws {
    exportedTombstoneURLs.append(url)
    try Data("fake-native-tombstone".utf8).write(to: url, options: [.atomic])
  }

  func restoreTombstone(from url: URL) throws {
    restoredTombstoneURLs.append(url)
    if let restoreError {
      throw restoreError
    }
  }

  func submitCoreRequestJSON(_ requestJSON: String) throws -> String {
    throw NSError(
      domain: "QixiNativeKataGo",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "fake bridge does not implement core requests"]
    )
  }

  func latestCoreSnapshotJSON() throws -> String {
    throw NSError(
      domain: "QixiNativeKataGo",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "fake bridge does not implement core snapshots"]
    )
  }

  func legalMoveMaskJSON() throws -> String {
    throw NSError(
      domain: "QixiNativeKataGo",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "fake bridge does not implement legal masks"]
    )
  }

  func exportCoreState(to url: URL) throws {
    throw NSError(
      domain: "QixiNativeKataGo",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "fake bridge does not implement core export"]
    )
  }

  func importCoreState(from url: URL) throws {
    throw NSError(
      domain: "QixiNativeKataGo",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "fake bridge does not implement core import"]
    )
  }
}

final class FakeHTTPAnalysisClient: QixiHTTPAnalysisClient {
  var statusResponse = BackendStatusResponse(
    engine: "none",
    engineId: nil,
    state: "fake HTTP ready",
    running: true,
    paused: false
  )
  var analysisResponse = AnalysisResponse(
    engine: "katago-metal-mux:b6",
    state: "fake HTTP analysis",
    positionKey: "backend-owned-position-key",
    winrate: 0.61,
    scoreMean: 2.5,
    visits: 64,
    moves: [
      AnalysisMove(x: 3, y: 3, move: "D16", visits: 64, winrate: 0.61, scoreMean: 2.5)
    ],
    ownership: Array(repeating: 0.0, count: 19 * 19)
  )
  private(set) var setEngineRequests: [AnalysisEngine] = []
  private(set) var analyzeRequest: (
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  )?

  func setEngine(_ engine: AnalysisEngine) async throws -> BackendStatusResponse {
    setEngineRequests.append(engine)
    return statusResponse
  }

  func analyze(
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse {
    analyzeRequest = (moves, setupStones, maxVisits, komi, rootNoise)
    return analysisResponse
  }
}

final class BackendClientSmokeURLProtocol: URLProtocol {
  struct Stub {
    var statusCode: Int
    var contentType: String?
    var body: Data
  }

  static var stub = Stub(
    statusCode: 200,
    contentType: "application/json",
    body: backendStatusJSON()
  )

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    var headers: [String: String] = [:]
    if let contentType = Self.stub.contentType {
      headers["Content-Type"] = contentType
    }
    let response = HTTPURLResponse(
      url: url,
      statusCode: Self.stub.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.stub.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

func backendClientSmokeClient(statusCode: Int = 200, contentType: String? = "application/json", body: Data) -> BackendClient {
  BackendClientSmokeURLProtocol.stub = BackendClientSmokeURLProtocol.Stub(
    statusCode: statusCode,
    contentType: contentType,
    body: body
  )
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [BackendClientSmokeURLProtocol.self]
  return BackendClient(
    baseURL: URL(string: "http://qixi-backend-client-smoke.local")!,
    session: URLSession(configuration: configuration)
  )
}

final class ReceiptWriteFailingFileManager: FileManager {
  private let targetModelPath: String
  private let receiptPath: String
  private let failingTargetCommitCall: Int
  private var targetCommitCalls = 0

  init(targetModelPath: String, receiptPath: String, failingTargetCommitCall: Int) {
    self.targetModelPath = targetModelPath
    self.receiptPath = receiptPath
    self.failingTargetCommitCall = failingTargetCommitCall
    super.init()
  }

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    try super.moveItem(at: srcURL, to: dstURL)
    if dstURL.path == targetModelPath {
      targetCommitCalls += 1
      if targetCommitCalls == failingTargetCommitCall {
        try createDirectory(at: URL(fileURLWithPath: receiptPath), withIntermediateDirectories: true)
      }
    }
  }
}

final class ReceiptUnknownSizeFileManager: FileManager {
  override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    throw CocoaError(.fileReadUnknown)
  }
}

final class ReceiptBackupMoveFailingFileManager: FileManager {
  private let receiptPath: String
  private let backupSuffixes: [String]

  init(receiptPath: String, backupSuffixes: [String] = [".receipt-backup"]) {
    self.receiptPath = receiptPath
    self.backupSuffixes = backupSuffixes
    super.init()
  }

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if srcURL.path == receiptPath && backupSuffixes.contains(where: { dstURL.lastPathComponent.hasSuffix($0) }) {
      throw CocoaError(.fileWriteUnknown)
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}

final class DestinationBackupMoveFailingFileManager: FileManager {
  private let destinationPath: String
  private let backupSuffixes: [String]

  init(destinationPath: String, backupSuffixes: [String]) {
    self.destinationPath = destinationPath
    self.backupSuffixes = backupSuffixes
    super.init()
  }

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if srcURL.path == destinationPath && backupSuffixes.contains(where: { dstURL.lastPathComponent.hasSuffix($0) }) {
      throw CocoaError(.fileWriteUnknown)
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}

final class RawStagedCopyCorruptingFileManager: FileManager {
  private let sourcePath: String

  init(sourcePath: String) {
    self.sourcePath = sourcePath
    super.init()
  }

  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    try super.copyItem(at: srcURL, to: dstURL)
    if srcURL.path == sourcePath && dstURL.lastPathComponent.hasSuffix(".tmp") {
      try Data("corrupt-staged-model".utf8).write(to: dstURL, options: [.atomic])
    }
  }
}

final class CoreMLStagedCopyCorruptingFileManager: FileManager {
  private let sourcePath: String

  init(sourcePath: String) {
    self.sourcePath = sourcePath
    super.init()
  }

  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    try super.copyItem(at: srcURL, to: dstURL)
    if srcURL.path == sourcePath && dstURL.lastPathComponent.hasSuffix(".coreml-package-tmp") {
      try Data("corrupt-coreml-model".utf8).write(to: dstURL.appendingPathComponent("Manifest.json"), options: [.atomic])
    }
  }
}

final class DestinationCommitFailingFileManager: FileManager {
  private let destinationPath: String
  private let failingDestinationMoveCall: Int
  private var destinationMoveCalls = 0

  init(destinationPath: String, failingDestinationMoveCall: Int) {
    self.destinationPath = destinationPath
    self.failingDestinationMoveCall = failingDestinationMoveCall
    super.init()
  }

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if dstURL.path == destinationPath {
      destinationMoveCalls += 1
      if destinationMoveCalls == failingDestinationMoveCall {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }
}

final class CoreMLPackageReceiptWriteFailingFileManager: FileManager {
  private let targetPackagePath: String
  private let receiptPath: String
  private let failingTargetCommitCall: Int
  private var targetCommitCalls = 0

  init(targetPackagePath: String, receiptPath: String, failingTargetCommitCall: Int) {
    self.targetPackagePath = targetPackagePath
    self.receiptPath = receiptPath
    self.failingTargetCommitCall = failingTargetCommitCall
    super.init()
  }

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    try super.moveItem(at: srcURL, to: dstURL)
    if dstURL.path == targetPackagePath {
      targetCommitCalls += 1
      if targetCommitCalls == failingTargetCommitCall {
        try createDirectory(at: URL(fileURLWithPath: receiptPath), withIntermediateDirectories: true)
      }
    }
  }
}

struct SharedPositionIdentityFixture: Decodable {
  var schemaVersion: Int
  var cases: [SharedPositionIdentityCase]
  var relations: [SharedPositionIdentityRelation]
}

struct SharedPositionIdentityCase: Decodable {
  var id: String
  var engine: String
  var backendEngine: String
  var rules: String
  var komi: Double
  var rootNoise: Double
  var moves: [SharedPositionIdentityMove]
}

struct SharedPositionIdentityMove: Decodable {
  var color: String
  var x: Int?
  var y: Int?
  var pass: Bool?

  func boardMove(caseID: String) -> BoardMove {
    let stoneColor: StoneColor
    switch color {
    case StoneColor.black.rawValue:
      stoneColor = .black
    case StoneColor.white.rawValue:
      stoneColor = .white
    default:
      AnalysisServiceSmoke.fail("shared position identity fixture case \(caseID) has invalid color \(color)")
    }

    if pass == true {
      if x != nil || y != nil {
        AnalysisServiceSmoke.fail("shared position identity fixture case \(caseID) pass move includes coordinates")
      }
      return BoardMove(pass: stoneColor)
    }

    guard let x, let y else {
      AnalysisServiceSmoke.fail("shared position identity fixture case \(caseID) non-pass move is missing coordinates")
    }
    return BoardMove(color: stoneColor, x: x, y: y)
  }
}

struct SharedPositionIdentityRelation: Decodable {
  var id: String
  var left: String
  var right: String
  var equal: Bool
  var sameVisibleStones: Bool
  var sameNextPlayer: Bool
  var reason: String
}

@main
struct AnalysisServiceSmoke {
  static func main() async {
    let suiteName = "qixi.analysis.service.smoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fail("could not create isolated defaults suite")
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    expect(
      QixiRuntimeConfig.analysisRuntime(environment: [:], defaults: defaults) == .httpBridge,
      "runtime defaults to the HTTP bridge in current development builds"
    )

    defaults.set("native-in-process", forKey: QixiRuntimeConfig.analysisRuntimeDefaultsKey)
    expect(
      QixiRuntimeConfig.analysisRuntime(environment: [:], defaults: defaults) == .nativeInProcess,
      "defaults can request native in-process analysis"
    )

    expect(
      QixiRuntimeConfig.analysisRuntime(
        environment: [QixiRuntimeConfig.analysisRuntimeEnvironmentKey: "mac-hosted-http"],
        defaults: defaults
      ) == .httpBridge,
      "environment overrides defaults for device smoke tests"
    )

    expect(
      QixiRuntimeConfig.analysisRuntime(
        environment: [QixiRuntimeConfig.analysisRuntimeEnvironmentKey: "iPad native"],
        defaults: defaults
      ) == .nativeInProcess,
      "runtime parser accepts the iPad-native alias"
    )

    let httpService = QixiAnalysisServiceFactory.makeService(runtime: .httpBridge)
    expect(httpService.runtime == .httpBridge, "factory builds HTTP bridge service")
    expect(httpService is HTTPBridgeAnalysisService, "HTTP bridge service type is explicit")
    expect(
      QixiAnalysisResponseValidationError.unknownEngine("katago-metal-mux:experimental").errorDescription?.contains("katago-metal-mux:experimental") == true,
      "unknown HTTP bridge engine responses are diagnosed explicitly"
    )

    let fakeHTTPClient = FakeHTTPAnalysisClient()
    let injectedHTTPService = HTTPBridgeAnalysisService(client: fakeHTTPClient)
    let httpMoves = [
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 15),
    ]
    do {
      let response = try await injectedHTTPService.analyze(
        moves: httpMoves,
        maxVisits: 64,
        komi: 7.5,
        rootNoise: 0.25
      )
      expect(
        fakeHTTPClient.analyzeRequest?.moves == httpMoves &&
          fakeHTTPClient.analyzeRequest?.maxVisits == 64 &&
          fakeHTTPClient.analyzeRequest?.komi == 7.5 &&
          fakeHTTPClient.analyzeRequest?.rootNoise == 0.25,
        "HTTP bridge forwards validated analysis requests to the injected client"
      )
      expect(
        response.positionKey == QixiPositionIdentity.cacheKey(
          engine: .b6,
          moves: httpMoves,
          komi: 7.5,
          rootNoise: 0.25
        ),
        "HTTP bridge overwrites backend-owned position keys with shared semantic cache keys"
      )
      expect(
        response.positionKey != "backend-owned-position-key" &&
          response.engine == "katago-metal-mux:b6" &&
          response.ownership.count == 19 * 19,
        "HTTP bridge preserves loaded analysis data while rejecting backend-owned cache identity"
      )
    } catch {
      fail("injected HTTP bridge should accept a valid b6 response: \(error)")
    }
    fakeHTTPClient.analysisResponse.engine = "katago-metal-mux:experimental"
    do {
      _ = try await injectedHTTPService.analyze(
        moves: httpMoves,
        maxVisits: 64,
        komi: 7.5,
        rootNoise: 0.25
      )
      fail("HTTP bridge must reject unknown backend engine IDs before UI caching")
    } catch QixiAnalysisResponseValidationError.unknownEngine(let engine) {
      expect(engine == "katago-metal-mux:experimental", "HTTP bridge unknown-engine error names the backend engine")
    } catch {
      fail("unexpected HTTP bridge unknown-engine error: \(error)")
    }

    do {
      let strictBackendClient = backendClientSmokeClient(
        contentType: "application/json; charset=utf-8",
        body: backendStatusJSON()
      )
      let status = try await strictBackendClient.setEngine(.none)
      expect(
        status.engine == "none" && status.running && !status.paused,
        "BackendClient accepts bounded application/json responses with charset parameters"
      )
    } catch {
      fail("BackendClient should accept a valid bounded JSON response: \(error)")
    }

    do {
      let failingStatusClient = backendClientSmokeClient(
        statusCode: 503,
        contentType: "application/json",
        body: backendStatusJSON()
      )
      _ = try await failingStatusClient.setEngine(.none)
      fail("BackendClient must reject non-2xx HTTP responses")
    } catch BackendClientResponseError.unacceptableStatusCode(let statusCode) {
      expect(statusCode == 503, "BackendClient reports the rejected HTTP status code")
    } catch {
      fail("unexpected BackendClient HTTP status error: \(error)")
    }

    do {
      let wrongTypeClient = backendClientSmokeClient(
        contentType: "text/html",
        body: backendStatusJSON()
      )
      _ = try await wrongTypeClient.setEngine(.none)
      fail("BackendClient must reject non-JSON content types")
    } catch BackendClientResponseError.missingJSONContentType(let contentType) {
      expect(contentType == "text/html", "BackendClient reports the rejected response content type")
    } catch {
      fail("unexpected BackendClient content-type error: \(error)")
    }

    do {
      let oversizedClient = backendClientSmokeClient(
        contentType: "application/json",
        body: Data(repeating: 0x20, count: BackendClient.maxResponseBytes + 1)
      )
      _ = try await oversizedClient.setEngine(.none)
      fail("BackendClient must reject oversized backend responses before decoding")
    } catch BackendClientResponseError.responseTooLarge(let bytes, let limit) {
      expect(
        bytes == BackendClient.maxResponseBytes + 1 && limit == BackendClient.maxResponseBytes,
        "BackendClient response-size error reports actual and limit bytes"
      )
    } catch {
      fail("unexpected BackendClient response-size error: \(error)")
    }

    do {
      let duplicateKeyClient = backendClientSmokeClient(
        contentType: "application/json",
        body: Data(
          """
          {"engine":"none","engine":"katago-metal-mux:b6","engineId":null,"state":"fake backend ready","running":true,"paused":false}
          """.utf8
        )
      )
      _ = try await duplicateKeyClient.setEngine(.none)
      fail("BackendClient must reject duplicate keys in bridge responses before decoding")
    } catch QixiStrictJSONError.duplicateKey(let label, let key) {
      expect(
        label == "Qixi HTTP bridge response" && key == "engine",
        "BackendClient strict JSON reports duplicate bridge response keys"
      )
    } catch {
      fail("unexpected BackendClient duplicate-key error: \(error)")
    }

    do {
      let nonStandardConstantClient = backendClientSmokeClient(
        contentType: "application/json",
        body: Data(
          """
          {"engine":"none","engineId":null,"state":"fake backend ready","running":true,"paused":NaN}
          """.utf8
        )
      )
      _ = try await nonStandardConstantClient.setEngine(.none)
      fail("BackendClient must reject non-standard constants in bridge responses before decoding")
    } catch QixiStrictJSONError.nonStandardConstant(let label, let value) {
      expect(
        label == "Qixi HTTP bridge response" && value == "NaN",
        "BackendClient strict JSON reports non-standard bridge response constants"
      )
    } catch {
      fail("unexpected BackendClient non-standard JSON constant error: \(error)")
    }

    do {
      let nonObjectClient = backendClientSmokeClient(
        contentType: "application/json",
        body: Data("[]".utf8)
      )
      _ = try await nonObjectClient.setEngine(.none)
      fail("BackendClient must reject non-object bridge responses before decoding")
    } catch QixiStrictJSONError.malformed(let label, let message) {
      expect(
        label == "Qixi HTTP bridge response" && message.contains("must be a JSON object"),
        "BackendClient strict JSON requires top-level bridge response objects"
      )
    } catch {
      fail("unexpected BackendClient non-object response error: \(error)")
    }

    let nativeService = QixiAnalysisServiceFactory.makeService(runtime: .nativeInProcess)
    expect(nativeService.runtime == .nativeInProcess, "factory builds native service entrypoint")
    expect(nativeService is NativeKataGoAnalysisService, "native service type is explicit")

    expect(QixiAnalysisLimits.isValidMaxVisits(1), "analysis limits accept the minimum visit count")
    expect(QixiAnalysisLimits.isValidMaxVisits(4096), "analysis limits accept the maximum visit count")
    expect(!QixiAnalysisLimits.isValidMaxVisits(0), "analysis limits reject zero visits")
    expect(QixiAnalysisLimits.isValidKomi(-150.0), "analysis limits accept minimum komi")
    expect(QixiAnalysisLimits.isValidKomi(150.0), "analysis limits accept maximum komi")
    expect(!QixiAnalysisLimits.isValidKomi(151.0), "analysis limits reject out-of-range komi")
    expect(QixiAnalysisLimits.normalizedKomi(151.0) == 150.0, "analysis limits clamp high UI komi input")
    expect(QixiAnalysisLimits.normalizedKomi(-151.0) == -150.0, "analysis limits clamp low UI komi input")
    expect(QixiAnalysisLimits.normalizedKomi(.infinity) == QixiAnalysisLimits.defaultKomi, "analysis limits reset non-finite UI komi input")
    expect(QixiAnalysisLimits.normalizedRootNoise(-0.01) == QixiAnalysisLimits.minRootNoise, "analysis limits clamp negative root noise to the floor")
    expect(QixiAnalysisLimits.normalizedRootNoise(.nan) == QixiAnalysisLimits.defaultRootNoise, "analysis limits reset non-finite root noise to the product default")
    expect(abs(QixiAnalysisLimits.defaultRootNoise - 0.04) < 1e-12, "first-launch root noise default is 0.04")
    expect(QixiAnalysisLimits.isValidRootNoise(0.0), "analysis limits still accept zero root noise")
    expect(QixiAnalysisLimits.isValidRootNoise(0.04), "analysis limits accept the first-launch default root noise")

    let validLoadedResponse = AnalysisResponse(
      engine: "katago-metal-mux:b6",
      state: "running",
      positionKey: "semantic-position-key",
      winrate: 0.54,
      scoreMean: 0.25,
      visits: 8,
      moves: [
        AnalysisMove(x: 3, y: 3, move: "D16", visits: 8, winrate: 0.54, scoreMean: 0.25)
      ],
      ownership: Array(repeating: 0.0, count: 19 * 19)
    )
    do {
      try QixiAnalysisResponseValidator.validate(validLoadedResponse, expectedEngine: .b6)
    } catch {
      fail("analysis response validator should accept a well-formed loaded response: \(error)")
    }
    let validNoEngineResponse = AnalysisResponse(
      engine: "none",
      state: "no engine loaded",
      positionKey: "none-position-key",
      winrate: nil,
      scoreMean: nil,
      visits: 0,
      moves: [],
      ownership: []
    )
    do {
      try QixiAnalysisResponseValidator.validate(validNoEngineResponse, expectedEngine: AnalysisEngine.none)
    } catch {
      fail("analysis response validator should accept an empty no-engine response: \(error)")
    }
    var invalidRootWinrateResponse = validLoadedResponse
    invalidRootWinrateResponse.winrate = 1.2
    do {
      try QixiAnalysisResponseValidator.validate(invalidRootWinrateResponse, expectedEngine: .b6)
      fail("analysis response validator must reject root winrate outside [0,1]")
    } catch QixiAnalysisResponseValidationError.invalidRootWinrate(let engine, let value) {
      expect(engine == "katago-metal-mux:b6" && value == 1.2, "invalid root winrate error is precise")
    } catch {
      fail("unexpected invalid root winrate error: \(error)")
    }
    var duplicateMoveResponse = validLoadedResponse
    duplicateMoveResponse.moves.append(AnalysisMove(x: 3, y: 3, move: "D16", visits: 1, winrate: 0.53, scoreMean: 0.1))
    do {
      try QixiAnalysisResponseValidator.validate(duplicateMoveResponse, expectedEngine: .b6)
      fail("analysis response validator must reject duplicate candidate moves")
    } catch QixiAnalysisResponseValidationError.duplicateMoveCoordinate(let index, let x, let y) {
      expect(index == 1 && x == 3 && y == 3, "duplicate candidate move error is precise")
    } catch {
      fail("unexpected duplicate candidate move error: \(error)")
    }
    var badOwnershipCountResponse = validLoadedResponse
    badOwnershipCountResponse.ownership = [0.0, 0.1]
    do {
      try QixiAnalysisResponseValidator.validate(badOwnershipCountResponse, expectedEngine: .b6)
      fail("analysis response validator must reject non-empty non-board-sized ownership")
    } catch QixiAnalysisResponseValidationError.invalidOwnershipCount(let count) {
      expect(count == 2, "invalid ownership count error is precise")
    } catch {
      fail("unexpected invalid ownership count error: \(error)")
    }
    var pollutedNoEngineResponse = validNoEngineResponse
    pollutedNoEngineResponse.moves = [
      AnalysisMove(x: 3, y: 3, move: "D16", visits: 1, winrate: 0.5, scoreMean: 0.0)
    ]
    do {
      try QixiAnalysisResponseValidator.validate(pollutedNoEngineResponse, expectedEngine: AnalysisEngine.none)
      fail("analysis response validator must reject non-empty no-engine analysis")
    } catch QixiAnalysisResponseValidationError.nonEmptyNoEngineAnalysis(let field) {
      expect(field == "moves", "no-engine pollution error names the non-empty field")
    } catch {
      fail("unexpected no-engine pollution error: \(error)")
    }

    let specs = QixiNativeModelRegistry.allSpecs()
    expect(specs.map(\.engine) == [.b6, .b18nbt, .b28nbt], "native registry covers the three real engines in UI order")
    for spec in specs {
      expect(!spec.resourceName.isEmpty, "native model resource name is present for \(spec.engine)")
      expect(spec.minimumMemoryMB > 0, "native model minimum memory is positive for \(spec.engine)")
      expect(spec.minimumMemoryMB <= spec.recommendedMemoryMB, "native memory minimum <= recommended for \(spec.engine)")
      expect(spec.recommendedMemoryMB <= spec.maximumMemoryMB, "native memory recommended <= maximum for \(spec.engine)")
    }
    expect(QixiNativeModelRegistry.spec(for: .b18nbt)?.resourceName == "b18nbt.bin", "b18 native model resource is stable")
    expect(QixiNativeModelRegistry.spec(for: .b28nbt)?.resourceName == "b28nbt.bin", "b28 native model resource is stable")
    expect(QixiNativeModelRegistry.spec(for: .none) == nil, "no-engine has no native model resource")
    guard let b6Spec = QixiNativeModelRegistry.spec(for: .b6) else {
      fail("b6 native model spec must exist")
    }
    let fileManager = FileManager.default
    let tempModelDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("qixi-native-model-store-\(UUID().uuidString)", isDirectory: true)
    do {
      try fileManager.createDirectory(at: tempModelDirectory, withIntermediateDirectories: true)
      try Data([0x71, 0x69, 0x78, 0x69]).write(to: tempModelDirectory.appendingPathComponent(b6Spec.resourceName))
    } catch {
      fail("could not create temporary native model store: \(error)")
    }
    defer {
      try? fileManager.removeItem(at: tempModelDirectory)
    }
    let testStore = QixiNativeModelStore(additionalSearchDirectories: [tempModelDirectory])
    expect(testStore.resolvedModel(for: b6Spec) == nil, "native model store rejects a wrong-size b6 file")
    do {
      try Data(count: Int(b6Spec.expectedByteCount)).write(to: tempModelDirectory.appendingPathComponent(b6Spec.resourceName))
    } catch {
      fail("could not create correctly sized temporary native model: \(error)")
    }
    guard let resolvedB6 = testStore.resolvedModel(for: b6Spec) else {
      fail("temporary native model store should resolve a size-matching b6")
    }
    expect(resolvedB6.fileURL.lastPathComponent == b6Spec.resourceName, "resolved b6 URL keeps resource name")
    expect(testStore.candidateURLs(for: b6Spec).contains(resolvedB6.fileURL), "candidate URLs include resolved b6")
    expect(b6Spec.sha256HexDigest.count == 64, "b6 model manifest carries a SHA-256 digest")
    let generousMemoryPolicy = QixiNativeDeviceMemoryPolicy(
      physicalMemoryBytes: UInt64(b6Spec.minimumMemoryMB + 1024) * 1_048_576,
      reservedSystemMemoryMB: 1024
    )
    expect(generousMemoryPolicy.canLoad(b6Spec), "native memory policy accepts a model at its minimum budget")
    let constrainedMemoryPolicy = QixiNativeDeviceMemoryPolicy(
      physicalMemoryBytes: UInt64(1024) * 1_048_576,
      reservedSystemMemoryMB: 1024
    )
    let constrainedReport = constrainedMemoryPolicy.report(for: b6Spec)
    expect(!constrainedMemoryPolicy.canLoad(b6Spec), "native memory policy rejects a model below its minimum budget")
    expect(
      constrainedReport.engine == .b6 &&
        constrainedReport.physicalMemoryMB == 1024 &&
        constrainedReport.availableMemoryMB == 0 &&
        constrainedReport.minimumMemoryMB == b6Spec.minimumMemoryMB,
      "native memory policy report names the model and memory budget precisely"
    )

    let lowMemoryBridge = FakeSwitchNativeKataGoBridge()
    let lowMemoryService = NativeKataGoAnalysisService(
      bridge: lowMemoryBridge,
      modelStore: testStore,
      memoryPolicy: constrainedMemoryPolicy
    )
    do {
      _ = try await lowMemoryService.setEngine(.b6)
      fail("native service must reject a present model when the device memory budget is too low")
    } catch QixiNativeKataGoServiceError.insufficientDeviceMemory(let report) {
      expect(
        report.engine == .b6 &&
          report.physicalMemoryMB == constrainedReport.physicalMemoryMB &&
          report.availableMemoryMB == constrainedReport.availableMemoryMB &&
          report.minimumMemoryMB == b6Spec.minimumMemoryMB,
        "native service low-memory error reports the selected model and available budget"
      )
      expect(
        lowMemoryBridge.loadedEngineIDs.isEmpty,
        "native service rejects a low-memory model before touching native engine state"
      )
      expect(
        lowMemoryBridge.configuredEngineIDs.isEmpty,
        "native service must not configure a real model below its minimum memory budget"
      )
      do {
        let lowMemoryResponse = try await lowMemoryService.analyze(
          moves: [],
          maxVisits: 1,
          komi: 7.5,
          rootNoise: 0.0
        )
        expect(
          lowMemoryResponse.positionKey == QixiPositionIdentity.cacheKey(
            engine: .none,
            moves: [],
            komi: 7.5,
            rootNoise: 0.0
          ),
          "native service analyzes as none after refusing a low-memory real-engine load"
        )
      } catch {
        fail("native service should remain usable as no-engine after low-memory refusal: \(error)")
      }
    } catch {
      fail("unexpected low-memory native engine load error: \(error)")
    }

    let fakeSwitchBridge = FakeSwitchNativeKataGoBridge()
    let fakeSwitchService = NativeKataGoAnalysisService(
      bridge: fakeSwitchBridge,
      modelStore: testStore,
      memoryPolicy: generousMemoryPolicy
    )
    do {
      let fakeB6Status = try await fakeSwitchService.setEngine(.b6)
      expect(
        fakeB6Status.engine == AnalysisEngine.b6.rawValue &&
          fakeB6Status.engineId == AnalysisEngine.b6.rawValue &&
          fakeB6Status.running,
        "native service status uses model identity for loaded b6"
      )
      expect(
        fakeSwitchBridge.configuredCoreMLPackagePaths == [[]],
        "native service passes resolved CoreML package paths to the bridge, empty when the manifest has none"
      )
      let b6Position = [BoardMove(color: .black, x: 3, y: 3)]
      let illegalAnalysisHistory = [
        BoardMove(color: .black, x: 3, y: 3),
        BoardMove(color: .white, x: 4, y: 3),
        BoardMove(color: .black, x: 3, y: 3),
      ]
      do {
        _ = try await fakeSwitchService.analyze(
          moves: illegalAnalysisHistory,
          maxVisits: 1,
          komi: 7.5,
          rootNoise: 0.0
        )
        fail("native service must reject illegal analysis history before entering the bridge")
      } catch QixiAnalysisInputValidationError.illegalMainLine(let ply) {
        expect(ply == 3, "analysis input validation reports the illegal history ply")
        expect(
          fakeSwitchBridge.analysisRequestJSONs.isEmpty,
          "analysis input validation rejects illegal history before bridge JSON serialization"
        )
      } catch {
        fail("unexpected illegal analysis history error: \(error)")
      }
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 0,
          komi: 7.5,
          rootNoise: 0.0
        )
        fail("native service must reject invalid maxVisits before entering the bridge")
      } catch QixiAnalysisInputValidationError.invalidMaxVisits(let value) {
        expect(value == 0, "analysis input validation reports invalid maxVisits")
        expect(
          fakeSwitchBridge.analysisRequestJSONs.isEmpty,
          "analysis input validation rejects invalid maxVisits before bridge JSON serialization"
        )
      } catch {
        fail("unexpected invalid maxVisits error: \(error)")
      }
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 1,
          komi: 151.0,
          rootNoise: 0.0
        )
        fail("native service must reject invalid komi before entering the bridge")
      } catch QixiAnalysisInputValidationError.invalidKomi(let value) {
        expect(value == 151.0, "analysis input validation reports invalid komi")
        expect(
          fakeSwitchBridge.analysisRequestJSONs.isEmpty,
          "analysis input validation rejects invalid komi before bridge JSON serialization"
        )
      } catch {
        fail("unexpected invalid komi error: \(error)")
      }
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 1,
          komi: 7.5,
          rootNoise: -0.01
        )
        fail("native service must reject invalid rootNoise before entering the bridge")
      } catch QixiAnalysisInputValidationError.invalidRootNoise(let value) {
        expect(value == -0.01, "analysis input validation reports invalid rootNoise")
        expect(
          fakeSwitchBridge.analysisRequestJSONs.isEmpty,
          "analysis input validation rejects invalid rootNoise before bridge JSON serialization"
        )
      } catch {
        fail("unexpected invalid rootNoise error: \(error)")
      }
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 1,
          komi: 7.5,
          rootNoise: 0.0
        )
        fail("loaded native service must reject a no-engine adapter response")
      } catch QixiNativeKataGoServiceError.invalidRequest(let message) {
        expect(
          message.contains("returned engine none while b6 is loaded"),
          "native service rejects adapter engine mismatch before caching analysis"
        )
      } catch {
        fail("unexpected native engine mismatch error: \(error)")
      }
      fakeSwitchBridge.analysisResponseJSON = loadedNativeAnalysisResponseJSON()
      let b6LoadedResponse = try await fakeSwitchService.analyze(
        moves: b6Position,
        maxVisits: 1,
        komi: 7.5,
        rootNoise: 0.0
      )
      expect(
        b6LoadedResponse.positionKey == QixiPositionIdentity.cacheKey(
          engine: .b6,
          moves: b6Position,
          komi: 7.5,
          rootNoise: 0.0
        ),
        "native service overwrites loaded adapter position keys with shared semantic cache keys"
      )
      expect(
        b6LoadedResponse.positionKey != "adapter-stale-position-key" &&
          b6LoadedResponse.ownership.count == 19 * 19,
        "native service keeps loaded ownership while rejecting adapter-owned cache identity"
      )
      expect(
        fakeSwitchBridge.analysisRequestJSONs.last?.contains(#""rules":"Chinese""#) == true,
        "native service serializes explicit Chinese rules into bridge analysis requests"
      )
      let photographedSetup = [
        BoardSetupStone(color: .black, x: 3, y: 3),
        BoardSetupStone(color: .white, x: 15, y: 15),
      ]
      let setupResponse = try await fakeSwitchService.analyze(
        moves: [],
        setupStones: photographedSetup,
        maxVisits: 64,
        komi: 7.5,
        rootNoise: 0.0
      )
      let setupRequestJSON = fakeSwitchBridge.analysisRequestJSONs.last ?? ""
      expect(
        setupResponse.positionKey == QixiPositionIdentity.cacheKey(
          engine: .b6,
          moves: [],
          setupStones: photographedSetup,
          komi: 7.5,
          rootNoise: 0.0
        ),
        "native service cache key keeps photographed setup stones distinct from ordered history"
      )
      expect(
        setupRequestJSON.contains(#""moves":[]"#) &&
          setupRequestJSON.contains(#""setupStones":["#) &&
          setupRequestJSON.contains(#""color":"B""#) &&
          setupRequestJSON.contains(#""x":3"#) &&
          setupRequestJSON.contains(#""y":3"#) &&
          setupRequestJSON.contains(#""color":"W""#) &&
          setupRequestJSON.contains(#""x":15"#) &&
          setupRequestJSON.contains(#""y":15"#) &&
          !setupRequestJSON.contains(#""pass":true"#),
        "native service serializes photographed stones as setupStones without fabricating move history"
      )
      fakeSwitchBridge.analysisResponseJSON = """
        {"engine":"b6","engine":"none","state":"ambiguous native analysis","positionKey":"adapter-stale-position-key","winrate":0.52,"scoreMean":1.25,"visits":1,"moves":[],"ownership":\(fullOwnershipJSON())}
        """
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 1,
          komi: 7.5,
          rootNoise: 0.0
        )
        fail("native service must reject duplicate keys in adapter responses before UI caching")
      } catch QixiNativeKataGoServiceError.invalidBridgeResponse(let message) {
        expect(
          message.contains("duplicate JSON key 'engine'"),
          "native bridge response validator reports duplicate adapter keys"
        )
      } catch {
        fail("unexpected duplicate-key native adapter response error: \(error)")
      }
      fakeSwitchBridge.analysisResponseJSON = loadedNativeAnalysisResponseJSON(winrate: "NaN")
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 1,
          komi: 7.5,
          rootNoise: 0.0
        )
        fail("native service must reject non-standard constants in adapter responses before decoding")
      } catch QixiNativeKataGoServiceError.invalidBridgeResponse(let message) {
        expect(
          message.contains("non-standard JSON constant NaN"),
          "native bridge response validator reports non-standard JSON constants"
        )
      } catch {
        fail("unexpected non-standard native adapter response error: \(error)")
      }
      fakeSwitchBridge.analysisResponseJSON = String(
        repeating: " ",
        count: NativeKataGoBridgeResponseValidator.maxResponseBytes + 1
      )
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 1,
          komi: 7.5,
          rootNoise: 0.0
        )
        fail("native service must reject oversized adapter responses before decoding")
      } catch QixiNativeKataGoServiceError.invalidBridgeResponse(let message) {
        expect(
          message.contains("exceeding the \(NativeKataGoBridgeResponseValidator.maxResponseBytes) byte limit"),
          "native bridge response validator reports oversized adapter responses"
        )
      } catch {
        fail("unexpected oversized native adapter response error: \(error)")
      }
      fakeSwitchBridge.analysisResponseJSON = loadedNativeAnalysisResponseJSON(
        movesJSON: #"[{"x":19,"y":3,"move":"T16","visits":1,"winrate":0.51,"scoreMean":0.0}]"#
      )
      do {
        _ = try await fakeSwitchService.analyze(
          moves: b6Position,
          maxVisits: 1,
          komi: 7.5,
          rootNoise: 0.0
        )
        fail("native service must reject malformed adapter candidate coordinates before UI caching")
      } catch QixiAnalysisResponseValidationError.invalidMoveCoordinate(let index, let x, let y) {
        expect(
          index == 0 && x == 19 && y == 3,
          "native service response validation reports malformed adapter candidate coordinates"
        )
      } catch {
        fail("unexpected malformed adapter candidate error: \(error)")
      }
      fakeSwitchBridge.analysisResponseJSON = noEngineNativeAnalysisResponseJSON()
      _ = try await fakeSwitchService.setEngine(.b18nbt)
      fail("fake native switch to b18 must fail because the b18 model is missing")
    } catch QixiNativeKataGoServiceError.modelMissing(let resourceName) {
      expect(resourceName == "b18nbt.bin", "fake native switch reports the missing b18 model")
    } catch {
      fail("unexpected fake native switch error: \(error)")
    }
    do {
      fakeSwitchBridge.analysisResponseJSON = loadedNativeAnalysisResponseJSON()
      let afterFailedSwitch = try await fakeSwitchService.analyze(
        moves: [],
        maxVisits: 1,
        komi: 7.5,
        rootNoise: 0.0
      )
      expect(
        afterFailedSwitch.positionKey == QixiPositionIdentity.cacheKey(
          engine: .b6,
          moves: [],
          komi: 7.5,
          rootNoise: 0.0
        ),
        "native service preserves currentEngine when a switch fails before bridge loading"
      )
      expect(
        fakeSwitchBridge.loadedEngineIDs == ["b6"],
        "native service leaves the committed bridge engine untouched when target validation fails"
      )
      expect(
        fakeSwitchBridge.configuredEngineIDs == ["b6"],
        "native service does not configure a missing model during failed switch"
      )
      let fakeEngineTombstoneURL = tempModelDirectory.appendingPathComponent("fake-engine-tombstone.qixi-native")
      try await fakeSwitchService.exportEngineTombstone(to: fakeEngineTombstoneURL)
      expect(
        (try? String(contentsOf: fakeEngineTombstoneURL, encoding: .utf8)) == "fake-native-tombstone",
        "native service exports engine tombstones through the bridge"
      )
      try await fakeSwitchService.restoreEngineTombstone(from: fakeEngineTombstoneURL, for: .none)
      expect(
        fakeSwitchBridge.exportedTombstoneURLs == [fakeEngineTombstoneURL] &&
          fakeSwitchBridge.restoredTombstoneURLs == [fakeEngineTombstoneURL],
        "native service restores no-engine tombstones through the bridge"
      )
      expect(
        fakeSwitchBridge.loadedEngineIDs.last == "none",
        "native service pins the bridge to none before restoring a no-engine tombstone"
      )

      let fakeRealRestoreBridge = FakeSwitchNativeKataGoBridge()
      let fakeRealRestoreService = NativeKataGoAnalysisService(
        bridge: fakeRealRestoreBridge,
        modelStore: testStore,
        memoryPolicy: generousMemoryPolicy
      )
      let fakeRealEngineTombstoneURL = tempModelDirectory.appendingPathComponent("fake-b6-engine-tombstone.qixi-native")
      try Data("fake-b6-native-tombstone".utf8).write(to: fakeRealEngineTombstoneURL, options: [.atomic])
      try await fakeRealRestoreService.restoreEngineTombstone(from: fakeRealEngineTombstoneURL, for: .b6)
      expect(
        fakeRealRestoreBridge.configuredEngineIDs == ["b6"] &&
          fakeRealRestoreBridge.loadedEngineIDs == ["b6"] &&
          fakeRealRestoreBridge.restoredTombstoneURLs == [fakeRealEngineTombstoneURL],
        "native service loads the requested real engine before restoring its tombstone"
      )

      let fakeFailingRestoreBridge = FakeSwitchNativeKataGoBridge()
      fakeFailingRestoreBridge.restoreError = NSError(
        domain: "QixiNativeKataGo",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "fake restore failure"]
      )
      let fakeFailingRestoreService = NativeKataGoAnalysisService(
        bridge: fakeFailingRestoreBridge,
        modelStore: testStore,
        memoryPolicy: generousMemoryPolicy
      )
      do {
        try await fakeFailingRestoreService.restoreEngineTombstone(from: fakeRealEngineTombstoneURL, for: .b6)
        fail("native service must surface real-engine tombstone restore failures")
      } catch QixiNativeKataGoServiceError.invalidRequest(let message) {
        expect(
          message.contains("fake restore failure"),
          "native service preserves real-engine tombstone restore diagnostics"
        )
      } catch {
        fail("unexpected real-engine tombstone restore failure error: \(error)")
      }
      expect(
        fakeFailingRestoreBridge.loadedEngineIDs == ["b6", "none"],
        "native service clears the loaded real engine after tombstone restore failure"
      )
      let afterFailedRestore = try await fakeFailingRestoreService.analyze(
        moves: [],
        maxVisits: 1,
        komi: 7.5,
        rootNoise: 0.0
      )
      expect(
        afterFailedRestore.positionKey == QixiPositionIdentity.cacheKey(
          engine: .none,
          moves: [],
          komi: 7.5,
          rootNoise: 0.0
        ),
        "native service analyzes as none after a real-engine tombstone restore failure"
      )
    } catch {
      fail("fake native service should analyze safely after failed switch: \(error)")
    }

    let failingUnloadBridge = FakeSwitchNativeKataGoBridge()
    let failingUnloadService = NativeKataGoAnalysisService(
      bridge: failingUnloadBridge,
      modelStore: testStore,
      memoryPolicy: generousMemoryPolicy
    )
    do {
      _ = try await failingUnloadService.setEngine(.b6)
      failingUnloadBridge.analysisResponseJSON = loadedNativeAnalysisResponseJSON()
      failingUnloadBridge.engineIDToFailOnLoad = AnalysisEngine.none.rawValue
      do {
        _ = try await failingUnloadService.setEngine(.none)
        fail("native service must surface a failed no-engine unload")
      } catch QixiNativeKataGoServiceError.invalidRequest(let message) {
        expect(message.contains("fake load failure for none"), "failed no-engine unload preserves bridge diagnostics")
      } catch {
        fail("unexpected failed no-engine unload error: \(error)")
      }
      let afterFailedUnload = try await failingUnloadService.analyze(
        moves: [],
        maxVisits: 1,
        komi: 7.5,
        rootNoise: 0.0
      )
      expect(
        afterFailedUnload.positionKey == QixiPositionIdentity.cacheKey(
          engine: .b6,
          moves: [],
          komi: 7.5,
          rootNoise: 0.0
        ),
        "native service preserves the committed engine after a failed no-engine unload"
      )
    } catch {
      fail("fake native service should protect state after failed no-engine unload: \(error)")
    }

    let integrityURL = tempModelDirectory.appendingPathComponent("tiny-integrity-model.bin")
    let tinySHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let tinySpec = NativeKataGoModelSpec(
      engine: .b6,
      resourceName: integrityURL.lastPathComponent,
      expectedByteCount: 3,
      sha256HexDigest: tinySHA256,
      minimumMemoryMB: 1,
      recommendedMemoryMB: 1,
      maximumMemoryMB: 1
    )
    do {
      try Data("abc".utf8).write(to: integrityURL)
      let integrityByteCount = try QixiNativeModelIntegrity.byteCount(of: integrityURL)
      expect(integrityByteCount == 3, "native model integrity reads byte count")
      expect(
        QixiNativeModelIntegrity.byteCountMatchesManifest(integrityURL, spec: tinySpec),
        "native model integrity accepts manifest byte count"
      )
      let integritySHA256 = try QixiNativeModelIntegrity.sha256HexDigest(of: integrityURL, chunkByteCount: 1)
      expect(integritySHA256 == tinySHA256, "native model integrity computes streaming SHA-256 with tiny chunks")
      let report = try QixiNativeModelIntegrity.verifyModel(at: integrityURL, spec: tinySpec, chunkByteCount: 2)
      expect(
        report == NativeKataGoModelIntegrityReport(
          resourceName: tinySpec.resourceName,
          byteCount: tinySpec.expectedByteCount,
          sha256HexDigest: tinySpec.sha256HexDigest
        ),
        "native model integrity report matches manifest"
      )
    } catch {
      fail("native model integrity should verify the tiny model: \(error)")
    }

    do {
      _ = try QixiNativeModelIntegrity.sha256HexDigest(of: integrityURL, chunkByteCount: 0)
      fail("native model integrity must reject a zero chunk size")
    } catch QixiNativeModelIntegrityError.invalidChunkSize(0) {
    } catch {
      fail("unexpected invalid chunk-size error: \(error)")
    }

    let symlinkIntegrityURL = tempModelDirectory.appendingPathComponent("linked-\(tinySpec.resourceName)")
    do {
      try? fileManager.removeItem(at: symlinkIntegrityURL)
      try fileManager.createSymbolicLink(atPath: symlinkIntegrityURL.path, withDestinationPath: integrityURL.path)
      _ = try QixiNativeModelIntegrity.verifyModel(at: symlinkIntegrityURL, spec: tinySpec, chunkByteCount: 2)
      fail("native model integrity must reject symbolic-link raw model files")
    } catch QixiNativeModelIntegrityError.symbolicLink(let path) {
      expect(path == symlinkIntegrityURL.path, "native model integrity reports the symbolic-link raw model path")
    } catch {
      fail("unexpected symbolic-link raw model integrity error: \(error)")
    }
    try? fileManager.removeItem(at: symlinkIntegrityURL)

    let symlinkParentDirectory = tempModelDirectory.appendingPathComponent("linked-model-parent", isDirectory: true)
    let symlinkParentTargetDirectory = tempModelDirectory.appendingPathComponent("linked-model-parent-target", isDirectory: true)
    do {
      try? fileManager.removeItem(at: symlinkParentDirectory)
      try? fileManager.removeItem(at: symlinkParentTargetDirectory)
      try fileManager.createDirectory(at: symlinkParentTargetDirectory, withIntermediateDirectories: true)
      try Data("abc".utf8).write(to: symlinkParentTargetDirectory.appendingPathComponent(tinySpec.resourceName))
      try fileManager.createSymbolicLink(atPath: symlinkParentDirectory.path, withDestinationPath: symlinkParentTargetDirectory.path)
      _ = try QixiNativeModelIntegrity.verifyModel(
        at: symlinkParentDirectory.appendingPathComponent(tinySpec.resourceName),
        spec: tinySpec,
        chunkByteCount: 2
      )
      fail("native model integrity must reject symbolic-link raw model path components")
    } catch QixiNativeModelIntegrityError.symbolicLink(let path) {
      expect(path == symlinkParentDirectory.path, "native model integrity reports the symbolic-link parent path")
    } catch {
      fail("unexpected symbolic-link parent raw model integrity error: \(error)")
    }
    try? fileManager.removeItem(at: symlinkParentDirectory)
    try? fileManager.removeItem(at: symlinkParentTargetDirectory)

    let directoryIntegrityURL = tempModelDirectory.appendingPathComponent("directory-\(tinySpec.resourceName)", isDirectory: true)
    do {
      try? fileManager.removeItem(at: directoryIntegrityURL)
      try fileManager.createDirectory(at: directoryIntegrityURL, withIntermediateDirectories: true)
      _ = try QixiNativeModelIntegrity.verifyModel(at: directoryIntegrityURL, spec: tinySpec, chunkByteCount: 2)
      fail("native model integrity must reject directory raw model files before hashing")
    } catch QixiNativeModelIntegrityError.notRegularFile(let path) {
      expect(path == directoryIntegrityURL.path, "native model integrity reports the non-regular raw model path")
    } catch {
      fail("unexpected directory raw model integrity error: \(error)")
    }
    try? fileManager.removeItem(at: directoryIntegrityURL)

    var wrongSizeSpec = tinySpec
    wrongSizeSpec.expectedByteCount = 4
    do {
      _ = try QixiNativeModelIntegrity.verifyModel(at: integrityURL, spec: wrongSizeSpec, chunkByteCount: 2)
      fail("native model integrity must reject byte-count drift")
    } catch QixiNativeModelIntegrityError.byteCountMismatch(let resourceName, let expected, let actual) {
      expect(resourceName == tinySpec.resourceName && expected == 4 && actual == 3, "byte-count drift error is precise")
    } catch {
      fail("unexpected byte-count drift error: \(error)")
    }

    var wrongHashSpec = tinySpec
    wrongHashSpec.sha256HexDigest = String(repeating: "0", count: 64)
    do {
      _ = try QixiNativeModelIntegrity.verifyModel(at: integrityURL, spec: wrongHashSpec, chunkByteCount: 2)
      fail("native model integrity must reject SHA-256 drift")
    } catch QixiNativeModelIntegrityError.sha256Mismatch(let resourceName, let expected, let actual) {
      expect(resourceName == tinySpec.resourceName, "SHA-256 drift error names the model")
      expect(expected == wrongHashSpec.sha256HexDigest, "SHA-256 drift error includes expected digest")
      expect(actual == tinySpec.sha256HexDigest, "SHA-256 drift error includes actual digest")
    } catch {
      fail("unexpected SHA-256 drift error: \(error)")
    }

    let coreMLSourcePackageURL = tempModelDirectory.appendingPathComponent(
      "source-tiny-19x19-fp16-mask-b2.mlpackage",
      isDirectory: true
    )
    let replacementCoreMLSourcePackageURL = tempModelDirectory.appendingPathComponent(
      "source-tiny-19x19-fp16-mask-b2-replacement.mlpackage",
      isDirectory: true
    )
    let coreMLPackageSpec: NativeKataGoCoreMLPackageSpec
    let replacementCoreMLPackageSpec: NativeKataGoCoreMLPackageSpec
    var tinySpecWithCoreML = tinySpec
    var replacementTinySpecWithCoreML = tinySpec
    do {
      try fileManager.createDirectory(
        at: coreMLSourcePackageURL.appendingPathComponent("Data", isDirectory: true),
        withIntermediateDirectories: true
      )
      try Data("coreml-model".utf8).write(to: coreMLSourcePackageURL.appendingPathComponent("Manifest.json"))
      try Data("weights".utf8).write(to: coreMLSourcePackageURL.appendingPathComponent("Data/weights.bin"))
      let packageReport = try QixiNativeCoreMLPackageIntegrity.packageTreeDigest(
        at: coreMLSourcePackageURL,
        chunkByteCount: 3
      )
      coreMLPackageSpec = NativeKataGoCoreMLPackageSpec(
        resourceName: "tiny-integrity-model.bin.coreml/19x19-fp16-mask-b2.mlpackage",
        variantID: "19x19-fp16-mask-b2",
        expectedFileCount: packageReport.fileCount,
        expectedTotalByteCount: packageReport.totalByteCount,
        sha256TreeDigest: packageReport.sha256TreeDigest
      )
      tinySpecWithCoreML.coreMLPackages = [coreMLPackageSpec]
      try fileManager.createDirectory(
        at: replacementCoreMLSourcePackageURL.appendingPathComponent("Data", isDirectory: true),
        withIntermediateDirectories: true
      )
      try Data("coreml-model-v2".utf8).write(to: replacementCoreMLSourcePackageURL.appendingPathComponent("Manifest.json"))
      try Data("weights-v2".utf8).write(to: replacementCoreMLSourcePackageURL.appendingPathComponent("Data/weights.bin"))
      let replacementPackageReport = try QixiNativeCoreMLPackageIntegrity.packageTreeDigest(
        at: replacementCoreMLSourcePackageURL,
        chunkByteCount: 3
      )
      var computedReplacementCoreMLPackageSpec = coreMLPackageSpec
      computedReplacementCoreMLPackageSpec.expectedFileCount = replacementPackageReport.fileCount
      computedReplacementCoreMLPackageSpec.expectedTotalByteCount = replacementPackageReport.totalByteCount
      computedReplacementCoreMLPackageSpec.sha256TreeDigest = replacementPackageReport.sha256TreeDigest
      replacementCoreMLPackageSpec = computedReplacementCoreMLPackageSpec
      replacementTinySpecWithCoreML.coreMLPackages = [replacementCoreMLPackageSpec]
      let verifiedPackage = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
        at: coreMLSourcePackageURL,
        packageSpec: coreMLPackageSpec,
        chunkByteCount: 2
      )
      expect(
        verifiedPackage.fileCount == 2 &&
          verifiedPackage.totalByteCount == packageReport.totalByteCount &&
          verifiedPackage.sha256TreeDigest == packageReport.sha256TreeDigest,
        "CoreML package integrity verifies recursive file count, byte count, and tree digest"
      )
      expect(
        verifiedPackage.totalByteCount == coreMLPackageSpec.expectedTotalByteCount,
        "CoreML package integrity validates opened package files before hashing"
      )
      expect(
        QixiNativeCoreMLPackageIntegrity.quickPackageMatchesManifest(
          coreMLSourcePackageURL,
          packageSpec: coreMLPackageSpec
        ),
        "CoreML package integrity quick check accepts matching file count and total bytes"
      )
      let extraCoreMLPackageFileURL = coreMLSourcePackageURL.appendingPathComponent("Data/extra.bin")
      try Data("extra".utf8).write(to: extraCoreMLPackageFileURL)
      expect(
        !QixiNativeCoreMLPackageIntegrity.quickPackageMatchesManifest(
          coreMLSourcePackageURL,
          packageSpec: coreMLPackageSpec
        ),
        "CoreML package integrity quick check rejects file-count budget overflow"
      )
      do {
        _ = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
          at: coreMLSourcePackageURL,
          packageSpec: coreMLPackageSpec,
          chunkByteCount: 2
        )
        fail("CoreML package integrity must reject file-count budget overflow before tree digest")
      } catch QixiNativeCoreMLPackageIntegrityError.fileCountMismatch(let resourceName, let expected, let actual) {
        expect(resourceName == coreMLPackageSpec.resourceName, "CoreML package file-count budget error names the package")
        expect(expected == coreMLPackageSpec.expectedFileCount, "CoreML package file-count budget error includes expected count")
        expect(actual == coreMLPackageSpec.expectedFileCount + 1, "CoreML package file-count budget error includes first overflowing count")
      } catch {
        fail("unexpected CoreML package file-count budget error: \(error)")
      }
      try fileManager.removeItem(at: extraCoreMLPackageFileURL)

      let coreMLPackageWeightsURL = coreMLSourcePackageURL.appendingPathComponent("Data/weights.bin")
      let originalCoreMLPackageWeights = try Data(contentsOf: coreMLPackageWeightsURL)
      var oversizedCoreMLPackageWeights = originalCoreMLPackageWeights
      oversizedCoreMLPackageWeights.append(Data("overflow".utf8))
      try oversizedCoreMLPackageWeights.write(to: coreMLPackageWeightsURL)
      expect(
        !QixiNativeCoreMLPackageIntegrity.quickPackageMatchesManifest(
          coreMLSourcePackageURL,
          packageSpec: coreMLPackageSpec
        ),
        "CoreML package integrity quick check rejects byte-count budget overflow"
      )
      do {
        _ = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
          at: coreMLSourcePackageURL,
          packageSpec: coreMLPackageSpec,
          chunkByteCount: 2
        )
        fail("CoreML package integrity must reject byte-count budget overflow before tree digest")
      } catch QixiNativeCoreMLPackageIntegrityError.byteCountMismatch(let resourceName, let expected, let actual) {
        expect(resourceName == coreMLPackageSpec.resourceName, "CoreML package byte-count budget error names the package")
        expect(expected == coreMLPackageSpec.expectedTotalByteCount, "CoreML package byte-count budget error includes expected bytes")
        expect(actual > coreMLPackageSpec.expectedTotalByteCount, "CoreML package byte-count budget error includes overflowing bytes")
      } catch {
        fail("unexpected CoreML package byte-count budget error: \(error)")
      }
      try originalCoreMLPackageWeights.write(to: coreMLPackageWeightsURL)

      do {
        _ = try QixiNativeCoreMLPackageIntegrity.packageTreeDigest(
          at: coreMLSourcePackageURL,
          chunkByteCount: 0
        )
        fail("CoreML package integrity must reject a zero chunk size")
      } catch QixiNativeCoreMLPackageIntegrityError.invalidChunkSize(0) {
      } catch {
        fail("unexpected CoreML package chunk-size error: \(error)")
      }
      var wrongPackageDigestSpec = coreMLPackageSpec
      wrongPackageDigestSpec.sha256TreeDigest = String(repeating: "0", count: 64)
      do {
        _ = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
          at: coreMLSourcePackageURL,
          packageSpec: wrongPackageDigestSpec,
          chunkByteCount: 2
        )
        fail("CoreML package integrity must reject tree digest drift")
      } catch QixiNativeCoreMLPackageIntegrityError.sha256Mismatch(let resourceName, let expected, let actual) {
        expect(resourceName == coreMLPackageSpec.resourceName, "CoreML package digest drift names the package")
        expect(expected == wrongPackageDigestSpec.sha256TreeDigest, "CoreML package digest drift includes expected digest")
        expect(actual == coreMLPackageSpec.sha256TreeDigest, "CoreML package digest drift includes actual digest")
      } catch {
        fail("unexpected CoreML package digest-drift error: \(error)")
      }
      let symlinkPackageURL = tempModelDirectory.appendingPathComponent("symlink-package.mlpackage", isDirectory: true)
      try fileManager.createDirectory(at: symlinkPackageURL, withIntermediateDirectories: true)
      try fileManager.createSymbolicLink(
        atPath: symlinkPackageURL.appendingPathComponent("link.bin").path,
        withDestinationPath: coreMLSourcePackageURL.appendingPathComponent("Manifest.json").path
      )
      do {
        _ = try QixiNativeCoreMLPackageIntegrity.packageTreeDigest(at: symlinkPackageURL)
        fail("CoreML package integrity must reject symbolic links")
      } catch QixiNativeCoreMLPackageIntegrityError.unsupportedPackageEntry {
      } catch {
        fail("unexpected CoreML symlink package error: \(error)")
      }
      let symlinkPackageParent = tempModelDirectory.appendingPathComponent("linked-package-parent", isDirectory: true)
      let symlinkPackageParentTarget = tempModelDirectory.appendingPathComponent("linked-package-parent-target", isDirectory: true)
      let symlinkParentPackageURL = symlinkPackageParent.appendingPathComponent("via-parent.mlpackage", isDirectory: true)
      let symlinkParentTargetPackageURL = symlinkPackageParentTarget.appendingPathComponent("via-parent.mlpackage", isDirectory: true)
      try? fileManager.removeItem(at: symlinkPackageParent)
      try? fileManager.removeItem(at: symlinkPackageParentTarget)
      try fileManager.createDirectory(at: symlinkParentTargetPackageURL.appendingPathComponent("Data", isDirectory: true), withIntermediateDirectories: true)
      try Data("manifest".utf8).write(to: symlinkParentTargetPackageURL.appendingPathComponent("Manifest.json"))
      try Data("weights".utf8).write(to: symlinkParentTargetPackageURL.appendingPathComponent("Data/weights.bin"))
      try fileManager.createSymbolicLink(atPath: symlinkPackageParent.path, withDestinationPath: symlinkPackageParentTarget.path)
      do {
        _ = try QixiNativeCoreMLPackageIntegrity.packageTreeDigest(at: symlinkParentPackageURL)
        fail("CoreML package integrity must reject symbolic-link package path components")
      } catch QixiNativeCoreMLPackageIntegrityError.packageNotDirectory(let path) {
        expect(path == symlinkPackageParent.path, "CoreML package integrity reports the symbolic-link parent path")
      } catch {
        fail("unexpected CoreML symlink parent package error: \(error)")
      }
      try? fileManager.removeItem(at: symlinkPackageParent)
      try? fileManager.removeItem(at: symlinkPackageParentTarget)
    } catch {
      fail("CoreML package integrity should verify the tiny package: \(error)")
    }

    let managedModelDirectory = tempModelDirectory.appendingPathComponent("managed-models", isDirectory: true)
    let installer: QixiNativeModelInstaller
    do {
      installer = try QixiNativeModelInstaller(fileManager: fileManager, modelsDirectory: managedModelDirectory)
    } catch {
      fail("could not create native model installer: \(error)")
    }
    let installSourceURL = tempModelDirectory.appendingPathComponent("install-source-\(tinySpec.resourceName)")
    let badInstallSourceURL = tempModelDirectory.appendingPathComponent("bad-install-source-\(tinySpec.resourceName)")
    do {
      try Data("abc".utf8).write(to: installSourceURL)
      try Data("abd".utf8).write(to: badInstallSourceURL)
    } catch {
      fail("could not create temporary installer sources: \(error)")
    }

    do {
      _ = try installer.installVerifiedModel(from: badInstallSourceURL, spec: tinySpec, chunkByteCount: 2)
      fail("native model installer must reject a wrong SHA-256 source before install")
    } catch QixiNativeModelIntegrityError.sha256Mismatch {
      let badDestination = managedModelDirectory.appendingPathComponent(tinySpec.resourceName)
      expect(!fileManager.fileExists(atPath: badDestination.path), "bad native model install leaves no destination")
    } catch {
      fail("unexpected bad native model install error: \(error)")
    }

    do {
      let stagedDriftDirectory = tempModelDirectory.appendingPathComponent("staged-drift-models", isDirectory: true)
      let stagedDriftFileManager = RawStagedCopyCorruptingFileManager(sourcePath: installSourceURL.path)
      let stagedDriftInstaller = try QixiNativeModelInstaller(
        fileManager: stagedDriftFileManager,
        modelsDirectory: stagedDriftDirectory
      )
      let stagedDriftDestinationURL = stagedDriftDirectory.appendingPathComponent(tinySpec.resourceName)
      do {
        _ = try stagedDriftInstaller.installVerifiedModel(
          from: installSourceURL,
          spec: tinySpec,
          chunkByteCount: 2
        )
        fail("native model installer must reject a raw model whose staged copy drifts after source verification")
      } catch QixiNativeModelIntegrityError.byteCountMismatch {
        expect(
          !stagedDriftFileManager.fileExists(atPath: stagedDriftDestinationURL.path),
          "native model installer leaves no destination after staged raw model drift"
        )
        let stagedDriftLeftovers = try installerArtifactRegularFileNames(
          in: stagedDriftDirectory,
          fileManager: stagedDriftFileManager
        )
        expect(
          stagedDriftLeftovers.isEmpty,
          "native model installer cleans temporary files after staged raw model drift"
        )
      } catch {
        fail("unexpected staged raw model drift error: \(error)")
      }
    } catch {
      fail("native model installer staged raw model drift test should not throw outside the install attempt: \(error)")
    }

    do {
      let firstCommitFailureDirectory = tempModelDirectory.appendingPathComponent("first-commit-failure-models", isDirectory: true)
      let firstCommitFailureDestinationURL = firstCommitFailureDirectory.appendingPathComponent(tinySpec.resourceName)
      let firstCommitFailureFileManager = DestinationCommitFailingFileManager(
        destinationPath: firstCommitFailureDestinationURL.path,
        failingDestinationMoveCall: 1
      )
      let firstCommitFailureInstaller = try QixiNativeModelInstaller(
        fileManager: firstCommitFailureFileManager,
        modelsDirectory: firstCommitFailureDirectory
      )
      do {
        _ = try firstCommitFailureInstaller.installVerifiedModel(
          from: installSourceURL,
          spec: tinySpec,
          chunkByteCount: 2
        )
        fail("native model installer must fail initial install when the staged model cannot be committed")
      } catch {
        expect(
          !firstCommitFailureFileManager.fileExists(atPath: firstCommitFailureDestinationURL.path),
          "native model installer leaves no model destination after initial staged commit failure"
        )
        let firstCommitFailureLeftovers = try installerArtifactRegularFileNames(
          in: firstCommitFailureDirectory,
          fileManager: firstCommitFailureFileManager
        )
        expect(
          firstCommitFailureLeftovers.isEmpty,
          "native model installer cleans temporary files after initial staged commit failure"
        )
      }
    } catch {
      fail("native model installer initial commit failure test should not throw outside the install attempt: \(error)")
    }

    do {
      let linkedManagedDirectory = tempModelDirectory.appendingPathComponent("linked-managed-models", isDirectory: true)
      let linkedManagedDirectoryTarget = tempModelDirectory.appendingPathComponent("linked-managed-models-target", isDirectory: true)
      try? fileManager.removeItem(at: linkedManagedDirectory)
      try? fileManager.removeItem(at: linkedManagedDirectoryTarget)
      try fileManager.createDirectory(at: linkedManagedDirectoryTarget, withIntermediateDirectories: true)
      try fileManager.createSymbolicLink(atPath: linkedManagedDirectory.path, withDestinationPath: linkedManagedDirectoryTarget.path)
      let linkedDirectoryInstaller = try QixiNativeModelInstaller(
        fileManager: fileManager,
        modelsDirectory: linkedManagedDirectory
      )
      do {
        _ = try linkedDirectoryInstaller.installVerifiedModel(from: installSourceURL, spec: tinySpec, chunkByteCount: 2)
        fail("native model installer rejects symbolic-link managed model directories")
      } catch let error as LocalizedError {
        let description = error.errorDescription ?? String(describing: error)
        expect(
          description.contains("symbolic links"),
          "native model installer managed-directory symlink error is explicit"
        )
        expect(
          !fileManager.fileExists(
            atPath: linkedManagedDirectoryTarget.appendingPathComponent(tinySpec.resourceName).path
          ),
          "native model installer does not write through symbolic-link managed directories"
        )
      } catch {
        fail("unexpected symbolic-link managed directory install error: \(error)")
      }
      try? fileManager.removeItem(at: linkedManagedDirectory)
      try? fileManager.removeItem(at: linkedManagedDirectoryTarget)
    } catch {
      fail("could not set up symbolic-link managed model directory smoke: \(error)")
    }

    do {
      let orphanCleanupDirectory = tempModelDirectory.appendingPathComponent("orphan-cleanup-models", isDirectory: true)
      try fileManager.createDirectory(at: orphanCleanupDirectory, withIntermediateDirectories: true)
      let orphanTemp = orphanCleanupDirectory.appendingPathComponent(".old-model.bin.dead.tmp")
      let orphanBackup = orphanCleanupDirectory.appendingPathComponent(".old-model.bin.dead.backup")
      let orphanReceiptBackup = orphanCleanupDirectory.appendingPathComponent(".old-model.bin.dead.receipt-backup")
      let orphanDirectory = orphanCleanupDirectory.appendingPathComponent(".old-model.bin.dead-directory.tmp", isDirectory: true)
      let orphanDirectorySentinel = orphanDirectory.appendingPathComponent("keep-me.txt")
      let orphanSymlink = orphanCleanupDirectory.appendingPathComponent(".old-model.bin.dead-symlink.tmp")
      let normalHiddenReceipt = orphanCleanupDirectory.appendingPathComponent(".tiny-integrity-model.bin.qixi-model-receipt.json")
      try Data("orphan-temp".utf8).write(to: orphanTemp)
      try Data("orphan-backup".utf8).write(to: orphanBackup)
      try Data("orphan-receipt-backup".utf8).write(to: orphanReceiptBackup)
      try fileManager.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
      try Data("directory-sentinel".utf8).write(to: orphanDirectorySentinel)
      try fileManager.createSymbolicLink(atPath: orphanSymlink.path, withDestinationPath: installSourceURL.path)
      try Data("keep-receipt".utf8).write(to: normalHiddenReceipt)
      let orphanCleanupInstaller = try QixiNativeModelInstaller(
        fileManager: fileManager,
        modelsDirectory: orphanCleanupDirectory
      )
      _ = try orphanCleanupInstaller.installVerifiedModel(from: installSourceURL, spec: tinySpec, chunkByteCount: 2)
      expect(!fileManager.fileExists(atPath: orphanTemp.path), "native model installer removes stale orphan tmp artifacts before install")
      expect(!fileManager.fileExists(atPath: orphanBackup.path), "native model installer removes stale orphan model backups before install")
      expect(
        !fileManager.fileExists(atPath: orphanReceiptBackup.path),
        "native model installer removes stale orphan receipt backups before install"
      )
      expect(
        fileManager.fileExists(atPath: normalHiddenReceipt.path),
        "native model installer does not remove ordinary hidden model receipt files during artifact cleanup"
      )
      expect(
        fileManager.fileExists(atPath: orphanDirectorySentinel.path),
        "native model installer does not recursively remove directory-shaped artifact names"
      )
      expect(
        (try? fileManager.destinationOfSymbolicLink(atPath: orphanSymlink.path)) == installSourceURL.path,
        "native model installer does not remove symbolic-link artifact names"
      )

      let protectedSourceURL = orphanCleanupDirectory.appendingPathComponent(".protected-source.bin.keep.tmp")
      let protectedSHA256 = "38ec21eb58ddf7ebb66697acecdc212d53b5c0b6fc57092f1c096874b73f7262"
      let protectedSpec = NativeKataGoModelSpec(
        engine: .b6,
        resourceName: "protected-cleanup-model.bin",
        expectedByteCount: 16,
        sha256HexDigest: protectedSHA256,
        minimumMemoryMB: 1,
        recommendedMemoryMB: 1,
        maximumMemoryMB: 1
      )
      try Data("protected-source".utf8).write(to: protectedSourceURL)
      let protectedInstall = try orphanCleanupInstaller.installVerifiedModel(
        from: protectedSourceURL,
        spec: protectedSpec,
        chunkByteCount: 4
      )
      expect(
        protectedInstall.resolvedModel.fileURL.lastPathComponent == protectedSpec.resourceName,
        "native model installer protects the current source URL while cleaning stale artifacts"
      )
    } catch {
      fail("native model installer should clean stale install artifacts safely: \(error)")
    }

    do {
      let modelBackupFailureDirectory = tempModelDirectory.appendingPathComponent("model-backup-failure-models", isDirectory: true)
      let modelBackupFailureDestinationURL = modelBackupFailureDirectory.appendingPathComponent(tinySpec.resourceName)
      let modelBackupFailureFileManager = DestinationBackupMoveFailingFileManager(
        destinationPath: modelBackupFailureDestinationURL.path,
        backupSuffixes: [".backup"]
      )
      let modelBackupFailureInstaller = try QixiNativeModelInstaller(
        fileManager: modelBackupFailureFileManager,
        modelsDirectory: modelBackupFailureDirectory
      )
      let modelBackupFailureOriginal = try modelBackupFailureInstaller.installVerifiedModel(
        from: installSourceURL,
        spec: tinySpec,
        chunkByteCount: 2
      )
      do {
        _ = try modelBackupFailureInstaller.installVerifiedModel(
          from: installSourceURL,
          spec: tinySpec,
          chunkByteCount: 2
        )
        fail("native model installer must fail replacement when the previous model cannot be backed up")
      } catch {
        let preservedModelData = try Data(contentsOf: modelBackupFailureOriginal.resolvedModel.fileURL)
        expect(
          preservedModelData == Data("abc".utf8),
          "native model installer preserves the previous model when model backup fails"
        )
        let modelBackupFailureStore = QixiNativeModelStore(
          additionalSearchDirectories: [modelBackupFailureDirectory],
          trustedInstallReceiptDirectories: [modelBackupFailureDirectory]
        )
        expect(
          modelBackupFailureStore.resolvedModel(for: tinySpec) == modelBackupFailureOriginal.resolvedModel,
          "native model installer preserves the previous receipt when model backup fails"
        )
        let modelBackupFailureLeftovers = try installerArtifactRegularFileNames(
          in: modelBackupFailureDirectory,
          fileManager: modelBackupFailureFileManager
        )
        expect(
          modelBackupFailureLeftovers.isEmpty,
          "native model installer cleans temporary, model backup, and receipt backup files after model backup failure"
        )
      }
    } catch {
      fail("native model installer model backup failure test should not throw outside the install attempt: \(error)")
    }

    do {
      let sabotagedReceiptDirectory = tempModelDirectory.appendingPathComponent("sabotaged-receipt-models", isDirectory: true)
      let sabotagedInstaller = try QixiNativeModelInstaller(fileManager: fileManager, modelsDirectory: sabotagedReceiptDirectory)
      let sabotagedDestination = sabotagedReceiptDirectory.appendingPathComponent(tinySpec.resourceName)
      let sabotagedReceiptURL = QixiNativeModelInstallReceiptStore.receiptURL(forModelAt: sabotagedDestination)
      try fileManager.createDirectory(at: sabotagedReceiptURL, withIntermediateDirectories: true)
      do {
        _ = try sabotagedInstaller.installVerifiedModel(from: installSourceURL, spec: tinySpec, chunkByteCount: 2)
        fail("native model installer must fail when the install receipt cannot be written")
      } catch {
        expect(
          !fileManager.fileExists(atPath: sabotagedDestination.path),
          "native model installer removes the committed model after receipt write failure"
        )
        let sabotagedLeftovers = try installerArtifactRegularFileNames(
          in: sabotagedReceiptDirectory,
          fileManager: fileManager
        ).filter { $0.hasSuffix(".tmp") }
        expect(
          sabotagedLeftovers.isEmpty,
          "native model installer cleans temporary files after receipt write failure"
        )
      }
    } catch {
      fail("could not set up sabotaged receipt install smoke: \(error)")
    }

    do {
      let installed = try installer.installVerifiedModel(from: installSourceURL, spec: tinySpec, chunkByteCount: 2)
      expect(installed.resolvedModel.spec == tinySpec, "native model installer returns the installed spec")
      expect(installed.resolvedModel.fileURL.lastPathComponent == tinySpec.resourceName, "native model installer uses manifest resource name")
      expect(installed.integrityReport.sha256HexDigest == tinySHA256, "native model installer returns verified SHA-256")
      let receiptURL = QixiNativeModelInstallReceiptStore.receiptURL(forModelAt: installed.resolvedModel.fileURL)
      expect(fileManager.fileExists(atPath: receiptURL.path), "native model installer writes an install receipt")
      expect(
        isExcludedFromBackup(managedModelDirectory),
        "native model installer excludes the managed model directory from iCloud backup"
      )
      expect(
        isExcludedFromBackup(installed.resolvedModel.fileURL),
        "native model installer excludes installed model files from iCloud backup"
      )
      expect(
        isExcludedFromBackup(receiptURL),
        "native model installer excludes model install receipts from iCloud backup"
      )
      let installedReceipt = try QixiNativeModelInstallReceiptStore.readReceipt(forModelAt: installed.resolvedModel.fileURL)
      let expectedInstalledReceipt = try QixiNativeModelInstallReceiptStore.receipt(
        forModelAt: installed.resolvedModel.fileURL,
        spec: tinySpec,
        fileManager: fileManager
      )
      expect(
        installedReceipt == expectedInstalledReceipt,
        "native model installer receipt matches the manifest"
      )
      expect(
        installedReceipt.installedByteCount == tinySpec.expectedByteCount &&
          installedReceipt.installedModificationTimeSince1970 > 0 &&
          installedReceipt.installedDeviceID >= 0 &&
          installedReceipt.installedFileID > 0,
        "native model installer receipt records the installed file metadata fingerprint"
      )
      let installedStore = QixiNativeModelStore(
        additionalSearchDirectories: [managedModelDirectory],
        trustedInstallReceiptDirectories: [managedModelDirectory]
      )
      expect(
        installedStore.resolvedModel(for: tinySpec) == installed.resolvedModel,
        "native model store resolves the installed verified model with a matching receipt"
      )
      let validModelReceiptData = try Data(contentsOf: receiptURL)
      let linkedModelReceiptTargetURL = managedModelDirectory.appendingPathComponent("linked-model-receipt-target.json")
      try validModelReceiptData.write(to: linkedModelReceiptTargetURL, options: [.atomic])
      try? fileManager.removeItem(at: receiptURL)
      try fileManager.createSymbolicLink(atPath: receiptURL.path, withDestinationPath: linkedModelReceiptTargetURL.path)
      expectThrows("native model receipt rejects symbolic-link receipt files") {
        _ = try QixiNativeModelInstallReceiptStore.readReceipt(forModelAt: installed.resolvedModel.fileURL)
      }
      expectThrows("native model receipt write rejects symbolic-link receipt paths") {
        try QixiNativeModelInstallReceiptStore.writeReceipt(
          forModelAt: installed.resolvedModel.fileURL,
          spec: tinySpec,
          fileManager: fileManager
        )
      }
      try? fileManager.removeItem(at: receiptURL)
      try? fileManager.removeItem(at: linkedModelReceiptTargetURL)
      try fileManager.createDirectory(at: receiptURL, withIntermediateDirectories: true)
      expectThrows("native model receipt rejects directory receipt files") {
        _ = try QixiNativeModelInstallReceiptStore.readReceipt(forModelAt: installed.resolvedModel.fileURL)
      }
      expect(
        installedStore.resolvedModel(for: tinySpec) == nil,
        "native model store rejects a managed model whose receipt is a directory"
      )
      try? fileManager.removeItem(at: receiptURL)
      try validModelReceiptData.write(to: receiptURL, options: [.atomic])
      let duplicateModelReceiptData = dataByReplacingFirst(
        in: validModelReceiptData,
        "\"schemaVersion\" : 3",
        "\"schemaVersion\" : 3, \"schemaVersion\" : 3"
      )
      try duplicateModelReceiptData.write(to: receiptURL, options: [.atomic])
      expectThrows("native model receipt rejects duplicate JSON keys") {
        _ = try QixiNativeModelInstallReceiptStore.readReceipt(forModelAt: installed.resolvedModel.fileURL)
      }
      expect(
        installedStore.resolvedModel(for: tinySpec) == nil,
        "native model store rejects a managed model whose receipt has duplicate JSON keys"
      )
      try validModelReceiptData.write(to: receiptURL, options: [.atomic])

      let nonStandardModelReceiptData = dataByReplacingFirst(
        in: validModelReceiptData,
        "\"installedByteCount\" : \(tinySpec.expectedByteCount)",
        "\"installedByteCount\" : NaN"
      )
      try nonStandardModelReceiptData.write(to: receiptURL, options: [.atomic])
      expectThrows("native model receipt rejects non-standard JSON constants") {
        _ = try QixiNativeModelInstallReceiptStore.readReceipt(forModelAt: installed.resolvedModel.fileURL)
      }
      try validModelReceiptData.write(to: receiptURL, options: [.atomic])

      try Data(repeating: 0x20, count: Int(QixiNativeModelInstallReceiptStore.maxReceiptBytes) + 1)
        .write(to: receiptURL, options: [.atomic])
      expectThrows("native model receipt rejects oversized JSON documents before decoding") {
        _ = try QixiNativeModelInstallReceiptStore.readReceipt(forModelAt: installed.resolvedModel.fileURL)
      }
      expect(
        installedStore.resolvedModel(for: tinySpec) == nil,
        "native model store rejects a managed model whose receipt is oversized"
      )
      try validModelReceiptData.write(to: receiptURL, options: [.atomic])

      try Data(repeating: 0x20, count: Int(QixiNativeModelInstallReceiptStore.maxReceiptBytes) + 2)
        .write(to: receiptURL, options: [.atomic])
      do {
        _ = try QixiNativeModelInstallReceiptStore.readReceipt(
          forModelAt: installed.resolvedModel.fileURL,
          fileManager: ReceiptUnknownSizeFileManager()
        )
        fail("native model receipt with unknown file size should be rejected by bounded read")
      } catch let error as LocalizedError {
        let description = error.errorDescription ?? ""
        expect(
          description.contains("\(QixiNativeModelInstallReceiptStore.maxReceiptBytes + 1)") &&
            description.contains("\(QixiNativeModelInstallReceiptStore.maxReceiptBytes)"),
          "native model receipt reader reads at most maxReceiptBytes plus one when file size is unavailable"
        )
      }
      try validModelReceiptData.write(to: receiptURL, options: [.atomic])

      let runtimeOrphanTemp = managedModelDirectory.appendingPathComponent(".runtime-orphan-model.bin.dead.tmp")
      let runtimeOrphanBackup = managedModelDirectory.appendingPathComponent(".runtime-orphan-model.bin.dead.backup")
      let runtimeOrphanReceiptBackup = managedModelDirectory.appendingPathComponent(".runtime-orphan-model.bin.dead.receipt-backup")
      let runtimeOrphanDirectory = managedModelDirectory.appendingPathComponent(".runtime-orphan-model.bin.dead-directory.tmp", isDirectory: true)
      let runtimeOrphanDirectorySentinel = runtimeOrphanDirectory.appendingPathComponent("keep-me.txt")
      let runtimeOrphanSymlink = managedModelDirectory.appendingPathComponent(".runtime-orphan-model.bin.dead-symlink.tmp")
      try Data("runtime-orphan-temp".utf8).write(to: runtimeOrphanTemp)
      try Data("runtime-orphan-backup".utf8).write(to: runtimeOrphanBackup)
      try Data("runtime-orphan-receipt-backup".utf8).write(to: runtimeOrphanReceiptBackup)
      try fileManager.createDirectory(at: runtimeOrphanDirectory, withIntermediateDirectories: true)
      try Data("runtime-directory-sentinel".utf8).write(to: runtimeOrphanDirectorySentinel)
      try fileManager.createSymbolicLink(atPath: runtimeOrphanSymlink.path, withDestinationPath: receiptURL.path)
      expect(
        installedStore.resolvedModel(for: tinySpec) == installed.resolvedModel,
        "native model store cleans stale orphan installer artifacts in trusted directories before resolving"
      )
      expect(
        !fileManager.fileExists(atPath: runtimeOrphanTemp.path) &&
          !fileManager.fileExists(atPath: runtimeOrphanBackup.path) &&
          !fileManager.fileExists(atPath: runtimeOrphanReceiptBackup.path),
        "native model store removes trusted runtime tmp, model backup, and receipt backup artifacts"
      )
      expect(
        fileManager.fileExists(atPath: receiptURL.path),
        "native model store preserves ordinary hidden receipts during trusted cleanup"
      )
      expect(
        fileManager.fileExists(atPath: runtimeOrphanDirectorySentinel.path),
        "native model store does not recursively remove directory-shaped artifact names during trusted cleanup"
      )
      expect(
        (try? fileManager.destinationOfSymbolicLink(atPath: runtimeOrphanSymlink.path)) == receiptURL.path,
        "native model store does not remove symbolic-link artifact names during trusted cleanup"
      )
      let untrustedCleanupDirectory = tempModelDirectory.appendingPathComponent("untrusted-runtime-cleanup-models", isDirectory: true)
      try fileManager.createDirectory(at: untrustedCleanupDirectory, withIntermediateDirectories: true)
      let untrustedOrphanTemp = untrustedCleanupDirectory.appendingPathComponent(".untrusted-runtime-orphan-model.bin.dead.tmp")
      try Data("untrusted-runtime-orphan-temp".utf8).write(to: untrustedOrphanTemp)
      let untrustedStore = QixiNativeModelStore(
        additionalSearchDirectories: [untrustedCleanupDirectory],
        trustedInstallReceiptDirectories: []
      )
      _ = untrustedStore.resolvedModel(for: tinySpec)
      expect(
        fileManager.fileExists(atPath: untrustedOrphanTemp.path),
        "native model store does not clean untrusted additional search directories"
      )
      try Data("xyz".utf8).write(to: installed.resolvedModel.fileURL, options: [.atomic])
      try fileManager.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: installedReceipt.installedModificationTimeSince1970)],
        ofItemAtPath: installed.resolvedModel.fileURL.path
      )
      expect(
        installedStore.resolvedModel(for: tinySpec) == nil,
        "native model store rejects a same-size managed model replaced after receipt even when mtime is restored"
      )
      let repeatInstall = try installer.installVerifiedModel(from: installSourceURL, spec: tinySpec, chunkByteCount: 2)
      expect(repeatInstall.resolvedModel == installed.resolvedModel, "native model installer can replace an existing model")
      let leftovers = try installerArtifactRegularFileNames(
        in: managedModelDirectory,
        fileManager: fileManager
      ).filter { $0.hasSuffix(".tmp") }
      expect(leftovers.isEmpty, "native model installer cleans temporary install files")

      let receiptBackupFailureDirectory = tempModelDirectory.appendingPathComponent("receipt-backup-failure-models", isDirectory: true)
      let receiptBackupDestinationURL = receiptBackupFailureDirectory.appendingPathComponent(tinySpec.resourceName)
      let receiptBackupReceiptURL = QixiNativeModelInstallReceiptStore.receiptURL(forModelAt: receiptBackupDestinationURL)
      let receiptBackupFileManager = ReceiptBackupMoveFailingFileManager(receiptPath: receiptBackupReceiptURL.path)
      let receiptBackupFailureInstaller = try QixiNativeModelInstaller(
        fileManager: receiptBackupFileManager,
        modelsDirectory: receiptBackupFailureDirectory
      )
      let receiptBackupOriginal = try receiptBackupFailureInstaller.installVerifiedModel(
        from: installSourceURL,
        spec: tinySpec,
        chunkByteCount: 2
      )
      do {
        _ = try receiptBackupFailureInstaller.installVerifiedModel(
          from: installSourceURL,
          spec: tinySpec,
          chunkByteCount: 2
        )
        fail("native model installer must fail replacement when the previous receipt cannot be backed up")
      } catch {
        let restoredModelData = try Data(contentsOf: receiptBackupOriginal.resolvedModel.fileURL)
        expect(
          restoredModelData == Data("abc".utf8),
          "native model installer preserves the previous model after receipt backup failure"
        )
        let receiptBackupStore = QixiNativeModelStore(
          additionalSearchDirectories: [receiptBackupFailureDirectory],
          trustedInstallReceiptDirectories: [receiptBackupFailureDirectory]
        )
        expect(
          receiptBackupStore.resolvedModel(for: tinySpec) == receiptBackupOriginal.resolvedModel,
          "native model installer preserves the previous receipt after receipt backup failure"
        )
        let receiptBackupLeftovers = try installerArtifactRegularFileNames(
          in: receiptBackupFailureDirectory,
          fileManager: fileManager
        )
        expect(
          receiptBackupLeftovers.isEmpty,
          "native model installer cleans temporary, model backup, and receipt backup files after receipt backup failure"
        )
      }

      let commitFailureDirectory = tempModelDirectory.appendingPathComponent("commit-failure-models", isDirectory: true)
      let commitFailureDestinationURL = commitFailureDirectory.appendingPathComponent(tinySpec.resourceName)
      let commitFailureFileManager = DestinationCommitFailingFileManager(
        destinationPath: commitFailureDestinationURL.path,
        failingDestinationMoveCall: 2
      )
      let commitFailureInstaller = try QixiNativeModelInstaller(
        fileManager: commitFailureFileManager,
        modelsDirectory: commitFailureDirectory
      )
      let commitFailureOriginal = try commitFailureInstaller.installVerifiedModel(
        from: installSourceURL,
        spec: tinySpec,
        chunkByteCount: 2
      )
      do {
        _ = try commitFailureInstaller.installVerifiedModel(
          from: installSourceURL,
          spec: tinySpec,
          chunkByteCount: 2
        )
        fail("native model installer must fail replacement when the staged model cannot be committed")
      } catch {
        let restoredModelData = try Data(contentsOf: commitFailureOriginal.resolvedModel.fileURL)
        expect(
          restoredModelData == Data("abc".utf8),
          "native model installer restores the previous model after staged commit failure"
        )
        let commitFailureStore = QixiNativeModelStore(
          additionalSearchDirectories: [commitFailureDirectory],
          trustedInstallReceiptDirectories: [commitFailureDirectory]
        )
        expect(
          commitFailureStore.resolvedModel(for: tinySpec) == commitFailureOriginal.resolvedModel,
          "native model installer restores the previous receipt after staged commit failure"
        )
        let commitFailureLeftovers = try installerArtifactRegularFileNames(
          in: commitFailureDirectory,
          fileManager: commitFailureFileManager
        )
        expect(
          commitFailureLeftovers.isEmpty,
          "native model installer cleans temporary, model backup, and receipt backup files after staged commit failure"
        )
      }

      let replacementFailureDirectory = tempModelDirectory.appendingPathComponent("replacement-receipt-failure-models", isDirectory: true)
      let replacementDestinationURL = replacementFailureDirectory.appendingPathComponent(tinySpec.resourceName)
      let replacementReceiptURL = QixiNativeModelInstallReceiptStore.receiptURL(forModelAt: replacementDestinationURL)
      let replacementFileManager = ReceiptWriteFailingFileManager(
        targetModelPath: replacementDestinationURL.path,
        receiptPath: replacementReceiptURL.path,
        failingTargetCommitCall: 2
      )
      let replacementFailureInstaller = try QixiNativeModelInstaller(
        fileManager: replacementFileManager,
        modelsDirectory: replacementFailureDirectory
      )
      let replacementOriginal = try replacementFailureInstaller.installVerifiedModel(
        from: installSourceURL,
        spec: tinySpec,
        chunkByteCount: 2
      )
      let replacementSourceURL = tempModelDirectory.appendingPathComponent("replacement-source-\(tinySpec.resourceName)")
      try Data("abd".utf8).write(to: replacementSourceURL)
      var replacementSpec = tinySpec
      replacementSpec.sha256HexDigest = try QixiNativeModelIntegrity.sha256HexDigest(
        of: replacementSourceURL,
        chunkByteCount: 2
      )
      do {
        _ = try replacementFailureInstaller.installVerifiedModel(
          from: replacementSourceURL,
          spec: replacementSpec,
          chunkByteCount: 2
        )
        fail("native model installer must fail replacement when the install receipt cannot be written")
      } catch {
        let restoredModelData = try Data(contentsOf: replacementOriginal.resolvedModel.fileURL)
        expect(
          restoredModelData == Data("abc".utf8),
          "native model installer preserves the previous model after replacement receipt failure"
        )
        let replacementStore = QixiNativeModelStore(
          additionalSearchDirectories: [replacementFailureDirectory],
          trustedInstallReceiptDirectories: [replacementFailureDirectory]
        )
        expect(
          replacementStore.resolvedModel(for: tinySpec) == replacementOriginal.resolvedModel,
          "native model installer restores the previous receipt after replacement receipt failure"
        )
        let replacementLeftovers = try installerArtifactRegularFileNames(
          in: replacementFailureDirectory,
          fileManager: fileManager
        )
        expect(
          replacementLeftovers.isEmpty,
          "native model installer cleans temporary, model backup, and receipt backup files after failed replacement"
        )
      }

      let recognizedDirectory = tempModelDirectory.appendingPathComponent("recognized-models", isDirectory: true)
      let recognizedInstaller = try QixiNativeModelInstaller(fileManager: fileManager, modelsDirectory: recognizedDirectory)
      let recognizedSpec = try recognizedInstaller.recognizedModelSpec(
        for: installSourceURL,
        specs: [wrongHashSpec, tinySpec],
        chunkByteCount: 2
      )
      expect(recognizedSpec == tinySpec, "native model installer identifies the verified manifest spec before install")
      let recognizedInstall = try recognizedInstaller.installRecognizedModel(
        from: installSourceURL,
        specs: [wrongHashSpec, tinySpec],
        chunkByteCount: 2
      )
      expect(
        recognizedInstall.resolvedModel.spec == tinySpec &&
          recognizedInstall.integrityReport.sha256HexDigest == tinySHA256,
        "native model installer recognizes a model from manifest byte count and SHA-256"
      )
      let unknownModelURL = tempModelDirectory.appendingPathComponent("unknown-model.bin")
      try Data("ab".utf8).write(to: unknownModelURL)
      do {
        _ = try recognizedInstaller.installRecognizedModel(from: unknownModelURL, specs: [tinySpec], chunkByteCount: 2)
        fail("native model installer must reject an unknown model package")
      } catch QixiNativeModelInstallerError.unrecognizedModel(let fileName) {
        expect(fileName == unknownModelURL.lastPathComponent, "native model installer rejects an unknown model package before staging")
      } catch {
        fail("unexpected unknown model install error: \(error)")
      }

      let coreMLManagedDirectory = tempModelDirectory.appendingPathComponent("managed-coreml-models", isDirectory: true)
      let coreMLInstaller = try QixiNativeModelInstaller(fileManager: fileManager, modelsDirectory: coreMLManagedDirectory)
      let coreMLRawInstall = try coreMLInstaller.installVerifiedModel(
        from: installSourceURL,
        spec: tinySpecWithCoreML,
        chunkByteCount: 2
      )
      let coreMLStoreBeforePackage = QixiNativeModelStore(
        additionalSearchDirectories: [coreMLManagedDirectory],
        trustedInstallReceiptDirectories: [coreMLManagedDirectory]
      )
      expect(
        coreMLStoreBeforePackage.resolvedModel(for: tinySpecWithCoreML) == nil,
        "native model store refuses a model whose required CoreML package is missing"
      )
      let packageMatch = NativeKataGoCoreMLPackageMatch(
        modelSpec: tinySpecWithCoreML,
        packageSpec: coreMLPackageSpec
      )
      let recognizedPackageMatch = try coreMLInstaller.recognizedCoreMLPackageMatch(
        for: coreMLSourcePackageURL,
        matches: [packageMatch],
        chunkByteCount: 2
      )
      expect(
        recognizedPackageMatch == packageMatch,
        "native model installer recognizes a CoreML package from recursive manifest metadata"
      )
      let coreMLPackageDestinationURL = coreMLManagedDirectory.appendingTrustedRelativePath(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLPackageDestinationDirectory = coreMLPackageDestinationURL.deletingLastPathComponent()
      let linkedCoreMLDestinationTarget = tempModelDirectory.appendingPathComponent(
        "linked-coreml-package-target",
        isDirectory: true
      )
      try? fileManager.removeItem(at: coreMLPackageDestinationDirectory)
      try? fileManager.removeItem(at: linkedCoreMLDestinationTarget)
      try fileManager.createDirectory(at: linkedCoreMLDestinationTarget, withIntermediateDirectories: true)
      try fileManager.createSymbolicLink(
        atPath: coreMLPackageDestinationDirectory.path,
        withDestinationPath: linkedCoreMLDestinationTarget.path
      )
      expectThrows("native model installer rejects symbolic-link CoreML package directories") {
        _ = try coreMLInstaller.installVerifiedCoreMLPackage(
          from: coreMLSourcePackageURL,
          match: packageMatch,
          chunkByteCount: 2
        )
      }
      try? fileManager.removeItem(at: coreMLPackageDestinationDirectory)
      try? fileManager.removeItem(at: linkedCoreMLDestinationTarget)
      try fileManager.createDirectory(at: coreMLPackageDestinationDirectory, withIntermediateDirectories: true)
      let staleCoreMLTemp = coreMLPackageDestinationDirectory.appendingPathComponent(
        ".stale.\(UUID().uuidString).coreml-package-tmp",
        isDirectory: true
      )
      let staleCoreMLBackup = coreMLPackageDestinationDirectory.appendingPathComponent(
        ".stale.\(UUID().uuidString).coreml-package-backup",
        isDirectory: true
      )
      let staleCoreMLReceiptBackup = coreMLPackageDestinationDirectory.appendingPathComponent(
        ".stale.\(UUID().uuidString).coreml-package-receipt-backup"
      )
      try fileManager.createDirectory(at: staleCoreMLTemp, withIntermediateDirectories: true)
      try Data("stale coreml temp".utf8).write(to: staleCoreMLTemp.appendingPathComponent("sentinel"))
      try fileManager.createDirectory(at: staleCoreMLBackup, withIntermediateDirectories: true)
      try Data("stale coreml backup".utf8).write(to: staleCoreMLBackup.appendingPathComponent("sentinel"))
      try Data("stale coreml receipt backup".utf8).write(to: staleCoreMLReceiptBackup)
      let staleCoreMLSymlink = coreMLPackageDestinationDirectory.appendingPathComponent(
        ".stale.\(UUID().uuidString).coreml-package-tmp"
      )
      try fileManager.createSymbolicLink(
        atPath: staleCoreMLSymlink.path,
        withDestinationPath: coreMLSourcePackageURL.path
      )
      let installedPackage = try coreMLInstaller.installVerifiedCoreMLPackage(
        from: coreMLSourcePackageURL,
        match: packageMatch,
        chunkByteCount: 2
      )
      expect(
        installedPackage.modelSpec == tinySpecWithCoreML &&
          installedPackage.packageSpec == coreMLPackageSpec &&
          installedPackage.integrityReport.sha256TreeDigest == coreMLPackageSpec.sha256TreeDigest,
        "native model installer installs a verified CoreML package beside the raw model"
      )

      let coreMLStagedDriftDirectory = tempModelDirectory.appendingPathComponent(
        "coreml-staged-drift-models",
        isDirectory: true
      )
      let coreMLStagedDriftDestinationURL = coreMLStagedDriftDirectory.appendingPathComponent(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLStagedDriftFileManager = CoreMLStagedCopyCorruptingFileManager(
        sourcePath: coreMLSourcePackageURL.path
      )
      let coreMLStagedDriftInstaller = try QixiNativeModelInstaller(
        fileManager: coreMLStagedDriftFileManager,
        modelsDirectory: coreMLStagedDriftDirectory
      )
      do {
        _ = try coreMLStagedDriftInstaller.installVerifiedCoreMLPackage(
          from: coreMLSourcePackageURL,
          match: packageMatch,
          chunkByteCount: 2
        )
        fail("native model installer must reject a CoreML package whose staged copy drifts after source verification")
      } catch QixiNativeCoreMLPackageIntegrityError.byteCountMismatch {
        expect(
          !coreMLStagedDriftFileManager.fileExists(atPath: coreMLStagedDriftDestinationURL.path),
          "native model installer leaves no CoreML package destination after staged package drift"
        )
        let coreMLStagedDriftLeftovers = try coreMLPackageArtifactNames(
          in: coreMLStagedDriftDestinationURL.deletingLastPathComponent(),
          fileManager: coreMLStagedDriftFileManager
        )
        expect(
          coreMLStagedDriftLeftovers.isEmpty,
          "native model installer cleans CoreML package temporary files after staged package drift"
        )
      } catch {
        fail("unexpected staged CoreML package drift error: \(error)")
      }

      let coreMLPackageBackupFailureDirectory = tempModelDirectory.appendingPathComponent(
        "coreml-package-backup-failure-models",
        isDirectory: true
      )
      let coreMLPackageBackupFailureDestinationURL = coreMLPackageBackupFailureDirectory.appendingPathComponent(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLPackageBackupFailureFileManager = DestinationBackupMoveFailingFileManager(
        destinationPath: coreMLPackageBackupFailureDestinationURL.path,
        backupSuffixes: [".coreml-package-backup"]
      )
      let coreMLPackageBackupFailureInstaller = try QixiNativeModelInstaller(
        fileManager: coreMLPackageBackupFailureFileManager,
        modelsDirectory: coreMLPackageBackupFailureDirectory
      )
      let coreMLPackageBackupFailureOriginal = try coreMLPackageBackupFailureInstaller.installVerifiedCoreMLPackage(
        from: coreMLSourcePackageURL,
        match: packageMatch,
        chunkByteCount: 2
      )
      do {
        _ = try coreMLPackageBackupFailureInstaller.installVerifiedCoreMLPackage(
          from: replacementCoreMLSourcePackageURL,
          match: NativeKataGoCoreMLPackageMatch(
            modelSpec: replacementTinySpecWithCoreML,
            packageSpec: replacementCoreMLPackageSpec
          ),
          chunkByteCount: 2
        )
        fail("native model installer must fail CoreML package replacement when the previous package cannot be backed up")
      } catch {
        let preservedManifestData = try Data(
          contentsOf: coreMLPackageBackupFailureOriginal.packageURL.appendingPathComponent("Manifest.json")
        )
        expect(
          preservedManifestData == Data("coreml-model".utf8),
          "native model installer preserves the previous CoreML package when package backup fails"
        )
        expect(
          QixiNativeCoreMLPackageInstallReceiptStore.receiptMatchesManifest(
            forPackageAt: coreMLPackageBackupFailureOriginal.packageURL,
            packageSpec: coreMLPackageSpec,
            fileManager: coreMLPackageBackupFailureFileManager
          ),
          "native model installer preserves the previous CoreML package receipt when package backup fails"
        )
        let coreMLPackageBackupFailureLeftovers = try coreMLPackageArtifactNames(
          in: coreMLPackageBackupFailureOriginal.packageURL.deletingLastPathComponent(),
          fileManager: coreMLPackageBackupFailureFileManager
        )
        expect(
          coreMLPackageBackupFailureLeftovers.isEmpty,
          "native model installer cleans CoreML package tmp, backup, and receipt backup artifacts after package backup failure"
        )
      }

      let coreMLFirstCommitFailureDirectory = tempModelDirectory.appendingPathComponent(
        "coreml-first-commit-failure-models",
        isDirectory: true
      )
      let coreMLFirstCommitFailureDestinationURL = coreMLFirstCommitFailureDirectory.appendingPathComponent(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLFirstCommitFailureFileManager = DestinationCommitFailingFileManager(
        destinationPath: coreMLFirstCommitFailureDestinationURL.path,
        failingDestinationMoveCall: 1
      )
      let coreMLFirstCommitFailureInstaller = try QixiNativeModelInstaller(
        fileManager: coreMLFirstCommitFailureFileManager,
        modelsDirectory: coreMLFirstCommitFailureDirectory
      )
      do {
        _ = try coreMLFirstCommitFailureInstaller.installVerifiedCoreMLPackage(
          from: coreMLSourcePackageURL,
          match: packageMatch,
          chunkByteCount: 2
        )
        fail("native model installer must fail CoreML package install when the staged package cannot be committed")
      } catch {
        expect(
          !coreMLFirstCommitFailureFileManager.fileExists(atPath: coreMLFirstCommitFailureDestinationURL.path),
          "native model installer leaves no CoreML package destination after initial staged commit failure"
        )
        let coreMLFirstCommitFailureLeftovers = try coreMLPackageArtifactNames(
          in: coreMLFirstCommitFailureDestinationURL.deletingLastPathComponent(),
          fileManager: coreMLFirstCommitFailureFileManager
        )
        expect(
          coreMLFirstCommitFailureLeftovers.isEmpty,
          "native model installer cleans CoreML package temporary files after initial staged commit failure"
        )
      }

      let coreMLFirstReceiptFailureDirectory = tempModelDirectory.appendingPathComponent(
        "coreml-first-receipt-failure-models",
        isDirectory: true
      )
      let coreMLFirstReceiptFailureDestinationURL = coreMLFirstReceiptFailureDirectory.appendingPathComponent(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLFirstReceiptFailureReceiptURL = QixiNativeCoreMLPackageInstallReceiptStore.receiptURL(
        forPackageAt: coreMLFirstReceiptFailureDestinationURL
      )
      let coreMLFirstReceiptFailureFileManager = CoreMLPackageReceiptWriteFailingFileManager(
        targetPackagePath: coreMLFirstReceiptFailureDestinationURL.path,
        receiptPath: coreMLFirstReceiptFailureReceiptURL.path,
        failingTargetCommitCall: 1
      )
      let coreMLFirstReceiptFailureInstaller = try QixiNativeModelInstaller(
        fileManager: coreMLFirstReceiptFailureFileManager,
        modelsDirectory: coreMLFirstReceiptFailureDirectory
      )
      do {
        _ = try coreMLFirstReceiptFailureInstaller.installVerifiedCoreMLPackage(
          from: coreMLSourcePackageURL,
          match: packageMatch,
          chunkByteCount: 2
        )
        fail("native model installer must fail CoreML package install when the package receipt cannot be written")
      } catch {
        expect(
          !coreMLFirstReceiptFailureFileManager.fileExists(atPath: coreMLFirstReceiptFailureDestinationURL.path),
          "native model installer removes the committed CoreML package after receipt write failure"
        )
        expect(
          !coreMLFirstReceiptFailureFileManager.fileExists(atPath: coreMLFirstReceiptFailureReceiptURL.path),
          "native model installer removes the failed CoreML package receipt path after receipt write failure"
        )
        let coreMLFirstReceiptFailureLeftovers = try coreMLPackageArtifactNames(
          in: coreMLFirstReceiptFailureDestinationURL.deletingLastPathComponent(),
          fileManager: coreMLFirstReceiptFailureFileManager
        )
        expect(
          coreMLFirstReceiptFailureLeftovers.isEmpty,
          "native model installer cleans CoreML package temporary files after receipt write failure"
        )
      }

      let coreMLReceiptBackupFailureDirectory = tempModelDirectory.appendingPathComponent(
        "coreml-receipt-backup-failure-models",
        isDirectory: true
      )
      let coreMLReceiptBackupDestinationURL = coreMLReceiptBackupFailureDirectory.appendingPathComponent(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLReceiptBackupReceiptURL = QixiNativeCoreMLPackageInstallReceiptStore.receiptURL(
        forPackageAt: coreMLReceiptBackupDestinationURL
      )
      let coreMLReceiptBackupFileManager = ReceiptBackupMoveFailingFileManager(
        receiptPath: coreMLReceiptBackupReceiptURL.path,
        backupSuffixes: [".coreml-package-receipt-backup"]
      )
      let coreMLReceiptBackupInstaller = try QixiNativeModelInstaller(
        fileManager: coreMLReceiptBackupFileManager,
        modelsDirectory: coreMLReceiptBackupFailureDirectory
      )
      let coreMLReceiptBackupOriginal = try coreMLReceiptBackupInstaller.installVerifiedCoreMLPackage(
        from: coreMLSourcePackageURL,
        match: packageMatch,
        chunkByteCount: 2
      )
      do {
        _ = try coreMLReceiptBackupInstaller.installVerifiedCoreMLPackage(
          from: replacementCoreMLSourcePackageURL,
          match: NativeKataGoCoreMLPackageMatch(
            modelSpec: replacementTinySpecWithCoreML,
            packageSpec: replacementCoreMLPackageSpec
          ),
          chunkByteCount: 2
        )
        fail("native model installer must fail CoreML package replacement when the previous package receipt cannot be backed up")
      } catch {
        let restoredManifestData = try Data(
          contentsOf: coreMLReceiptBackupOriginal.packageURL.appendingPathComponent("Manifest.json")
        )
        expect(
          restoredManifestData == Data("coreml-model".utf8),
          "native model installer preserves the previous CoreML package after receipt backup failure"
        )
        expect(
          QixiNativeCoreMLPackageInstallReceiptStore.receiptMatchesManifest(
            forPackageAt: coreMLReceiptBackupOriginal.packageURL,
            packageSpec: coreMLPackageSpec,
            fileManager: coreMLReceiptBackupFileManager
          ),
          "native model installer preserves the previous CoreML package receipt after receipt backup failure"
        )
        let coreMLReceiptBackupLeftovers = try coreMLPackageArtifactNames(
          in: coreMLReceiptBackupOriginal.packageURL.deletingLastPathComponent(),
          fileManager: coreMLReceiptBackupFileManager
        )
        expect(
          coreMLReceiptBackupLeftovers.isEmpty,
          "native model installer cleans CoreML package tmp, backup, and receipt backup artifacts after receipt backup failure"
        )
      }

      let coreMLCommitFailureDirectory = tempModelDirectory.appendingPathComponent(
        "coreml-commit-failure-models",
        isDirectory: true
      )
      let coreMLCommitFailureDestinationURL = coreMLCommitFailureDirectory.appendingPathComponent(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLCommitFailureFileManager = DestinationCommitFailingFileManager(
        destinationPath: coreMLCommitFailureDestinationURL.path,
        failingDestinationMoveCall: 2
      )
      let coreMLCommitFailureInstaller = try QixiNativeModelInstaller(
        fileManager: coreMLCommitFailureFileManager,
        modelsDirectory: coreMLCommitFailureDirectory
      )
      let coreMLCommitFailureOriginal = try coreMLCommitFailureInstaller.installVerifiedCoreMLPackage(
        from: coreMLSourcePackageURL,
        match: packageMatch,
        chunkByteCount: 2
      )
      do {
        _ = try coreMLCommitFailureInstaller.installVerifiedCoreMLPackage(
          from: replacementCoreMLSourcePackageURL,
          match: NativeKataGoCoreMLPackageMatch(
            modelSpec: replacementTinySpecWithCoreML,
            packageSpec: replacementCoreMLPackageSpec
          ),
          chunkByteCount: 2
        )
        fail("native model installer must fail CoreML package replacement when the staged package cannot be committed")
      } catch {
        let restoredManifestData = try Data(
          contentsOf: coreMLCommitFailureOriginal.packageURL.appendingPathComponent("Manifest.json")
        )
        expect(
          restoredManifestData == Data("coreml-model".utf8),
          "native model installer restores the previous CoreML package after staged commit failure"
        )
        expect(
          QixiNativeCoreMLPackageInstallReceiptStore.receiptMatchesManifest(
            forPackageAt: coreMLCommitFailureOriginal.packageURL,
            packageSpec: coreMLPackageSpec,
            fileManager: coreMLCommitFailureFileManager
          ),
          "native model installer restores the previous CoreML package receipt after staged commit failure"
        )
        let coreMLCommitFailureLeftovers = try coreMLPackageArtifactNames(
          in: coreMLCommitFailureOriginal.packageURL.deletingLastPathComponent(),
          fileManager: coreMLCommitFailureFileManager
        )
        expect(
          coreMLCommitFailureLeftovers.isEmpty,
          "native model installer cleans CoreML package tmp, backup, and receipt backup artifacts after staged commit failure"
        )
      }

      let coreMLReplacementFailureDirectory = tempModelDirectory.appendingPathComponent(
        "coreml-replacement-receipt-failure-models",
        isDirectory: true
      )
      let coreMLReplacementDestinationURL = coreMLReplacementFailureDirectory.appendingPathComponent(
        coreMLPackageSpec.resourceName,
        isDirectory: true
      )
      let coreMLReplacementReceiptURL = QixiNativeCoreMLPackageInstallReceiptStore.receiptURL(
        forPackageAt: coreMLReplacementDestinationURL
      )
      let coreMLReplacementFileManager = CoreMLPackageReceiptWriteFailingFileManager(
        targetPackagePath: coreMLReplacementDestinationURL.path,
        receiptPath: coreMLReplacementReceiptURL.path,
        failingTargetCommitCall: 2
      )
      let coreMLReplacementInstaller = try QixiNativeModelInstaller(
        fileManager: coreMLReplacementFileManager,
        modelsDirectory: coreMLReplacementFailureDirectory
      )
      let coreMLReplacementOriginal = try coreMLReplacementInstaller.installVerifiedCoreMLPackage(
        from: coreMLSourcePackageURL,
        match: packageMatch,
        chunkByteCount: 2
      )
      do {
        _ = try coreMLReplacementInstaller.installVerifiedCoreMLPackage(
          from: replacementCoreMLSourcePackageURL,
          match: NativeKataGoCoreMLPackageMatch(
            modelSpec: replacementTinySpecWithCoreML,
            packageSpec: replacementCoreMLPackageSpec
          ),
          chunkByteCount: 2
        )
        fail("native model installer must fail CoreML package replacement when the package receipt cannot be written")
      } catch {
        let restoredManifestData = try Data(
          contentsOf: coreMLReplacementOriginal.packageURL.appendingPathComponent("Manifest.json")
        )
        expect(
          restoredManifestData == Data("coreml-model".utf8),
          "native model installer preserves the previous CoreML package after replacement receipt failure"
        )
        expect(
          QixiNativeCoreMLPackageInstallReceiptStore.receiptMatchesManifest(
            forPackageAt: coreMLReplacementOriginal.packageURL,
            packageSpec: coreMLPackageSpec,
            fileManager: coreMLReplacementFileManager
          ),
          "native model installer restores the previous CoreML package receipt after replacement receipt failure"
        )
        let coreMLReplacementLeftovers = try coreMLPackageArtifactNames(
          in: coreMLReplacementOriginal.packageURL.deletingLastPathComponent(),
          fileManager: coreMLReplacementFileManager
        )
        expect(
          coreMLReplacementLeftovers.isEmpty,
          "native model installer cleans CoreML package tmp, backup, and receipt backup artifacts after failed replacement"
        )
      }

      let packageReceiptURL = QixiNativeCoreMLPackageInstallReceiptStore.receiptURL(forPackageAt: installedPackage.packageURL)
      expect(fileManager.fileExists(atPath: packageReceiptURL.path), "native model installer writes a CoreML package receipt")
      expect(isExcludedFromBackup(installedPackage.packageURL), "native model installer excludes CoreML package directories from iCloud backup")
      expect(isExcludedFromBackup(packageReceiptURL), "native model installer excludes CoreML package receipts from iCloud backup")
      let validPackageReceiptData = try Data(contentsOf: packageReceiptURL)
      let linkedPackageReceiptTargetURL = coreMLPackageDestinationDirectory.appendingPathComponent("linked-coreml-package-receipt-target.json")
      try validPackageReceiptData.write(to: linkedPackageReceiptTargetURL, options: [.atomic])
      try? fileManager.removeItem(at: packageReceiptURL)
      try fileManager.createSymbolicLink(atPath: packageReceiptURL.path, withDestinationPath: linkedPackageReceiptTargetURL.path)
      expectThrows("native CoreML package receipt rejects symbolic-link receipt files") {
        _ = try QixiNativeCoreMLPackageInstallReceiptStore.readReceipt(forPackageAt: installedPackage.packageURL)
      }
      expectThrows("native CoreML package receipt write rejects symbolic-link receipt paths") {
        try QixiNativeCoreMLPackageInstallReceiptStore.writeReceipt(
          forPackageAt: installedPackage.packageURL,
          packageSpec: coreMLPackageSpec,
          fileManager: fileManager,
          chunkByteCount: 2
        )
      }
      try? fileManager.removeItem(at: packageReceiptURL)
      try? fileManager.removeItem(at: linkedPackageReceiptTargetURL)
      try fileManager.createDirectory(at: packageReceiptURL, withIntermediateDirectories: true)
      expectThrows("native CoreML package receipt rejects directory receipt files") {
        _ = try QixiNativeCoreMLPackageInstallReceiptStore.readReceipt(forPackageAt: installedPackage.packageURL)
      }
      try? fileManager.removeItem(at: packageReceiptURL)
      try validPackageReceiptData.write(to: packageReceiptURL, options: [.atomic])
      let duplicatePackageReceiptData = dataByReplacingFirst(
        in: validPackageReceiptData,
        "\"schemaVersion\" : 1",
        "\"schemaVersion\" : 1, \"schemaVersion\" : 1"
      )
      try duplicatePackageReceiptData.write(to: packageReceiptURL, options: [.atomic])
      expectThrows("native CoreML package receipt rejects duplicate JSON keys") {
        _ = try QixiNativeCoreMLPackageInstallReceiptStore.readReceipt(forPackageAt: installedPackage.packageURL)
      }
      try validPackageReceiptData.write(to: packageReceiptURL, options: [.atomic])

      try Data(repeating: 0x20, count: Int(QixiNativeCoreMLPackageInstallReceiptStore.maxReceiptBytes) + 1)
        .write(to: packageReceiptURL, options: [.atomic])
      expectThrows("native CoreML package receipt rejects oversized JSON documents before decoding") {
        _ = try QixiNativeCoreMLPackageInstallReceiptStore.readReceipt(forPackageAt: installedPackage.packageURL)
      }
      try validPackageReceiptData.write(to: packageReceiptURL, options: [.atomic])

      try Data(repeating: 0x20, count: Int(QixiNativeCoreMLPackageInstallReceiptStore.maxReceiptBytes) + 2)
        .write(to: packageReceiptURL, options: [.atomic])
      do {
        _ = try QixiNativeCoreMLPackageInstallReceiptStore.readReceipt(
          forPackageAt: installedPackage.packageURL,
          fileManager: ReceiptUnknownSizeFileManager()
        )
        fail("native CoreML package receipt with unknown file size should be rejected by bounded read")
      } catch let error as LocalizedError {
        let description = error.errorDescription ?? ""
        expect(
          description.contains("\(QixiNativeCoreMLPackageInstallReceiptStore.maxReceiptBytes + 1)") &&
            description.contains("\(QixiNativeCoreMLPackageInstallReceiptStore.maxReceiptBytes)"),
          "native CoreML package receipt reader reads at most maxReceiptBytes plus one when file size is unavailable"
        )
      }
      try validPackageReceiptData.write(to: packageReceiptURL, options: [.atomic])

      let coreMLPackageInstallLeftovers = try coreMLPackageArtifactNames(
        in: coreMLPackageDestinationDirectory,
        fileManager: fileManager
      )
      expect(
        coreMLPackageInstallLeftovers.isEmpty,
        "native model installer removes stale CoreML package tmp, backup, and receipt-backup artifacts before install"
      )
      expect(
        (try? fileManager.destinationOfSymbolicLink(atPath: staleCoreMLSymlink.path)) == coreMLSourcePackageURL.path,
        "native model installer does not remove symbolic-link CoreML package artifact names"
      )
      let runtimeStaleCoreMLTemp = coreMLPackageDestinationDirectory.appendingPathComponent(
        ".runtime.\(UUID().uuidString).coreml-package-tmp",
        isDirectory: true
      )
      try fileManager.createDirectory(at: runtimeStaleCoreMLTemp, withIntermediateDirectories: true)
      try Data("runtime coreml temp".utf8).write(to: runtimeStaleCoreMLTemp.appendingPathComponent("sentinel"))
      let coreMLStoreAfterPackage = QixiNativeModelStore(
        additionalSearchDirectories: [coreMLManagedDirectory],
        trustedInstallReceiptDirectories: [coreMLManagedDirectory]
      )
      guard let resolvedWithPackage = coreMLStoreAfterPackage.resolvedModel(for: tinySpecWithCoreML) else {
        fail("native model store should resolve a raw model once its required CoreML package is installed")
      }
      expect(
        resolvedWithPackage.fileURL == coreMLRawInstall.resolvedModel.fileURL &&
          resolvedWithPackage.coreMLPackageURLs == [installedPackage.packageURL],
        "native model store returns the installed CoreML package URL with the raw model"
      )
      let coreMLPackageRuntimeLeftovers = try coreMLPackageArtifactNames(
        in: coreMLPackageDestinationDirectory,
        fileManager: fileManager
      )
      expect(
        coreMLPackageRuntimeLeftovers.isEmpty,
        "native model store removes trusted CoreML package tmp artifacts before resolving"
      )
      try Data("Xoreml-model".utf8).write(to: installedPackage.packageURL.appendingPathComponent("Manifest.json"), options: [.atomic])
      expect(
        coreMLStoreAfterPackage.resolvedModel(for: tinySpecWithCoreML) == nil,
        "native model store rejects a same-size CoreML package changed after receipt"
      )
      do {
        _ = try coreMLInstaller.installRecognizedCoreMLPackage(
          from: unknownModelURL,
          matches: [packageMatch],
          chunkByteCount: 2
        )
        fail("native model installer must reject an unknown CoreML package before staging")
      } catch QixiNativeModelInstallerError.unrecognizedCoreMLPackage(let fileName) {
        expect(fileName == unknownModelURL.lastPathComponent, "native model installer rejects an unknown CoreML package precisely")
      } catch {
        fail("unexpected unknown CoreML package install error: \(error)")
      }

      try fileManager.removeItem(at: receiptURL)
      expect(installedStore.resolvedModel(for: tinySpec) == nil, "native model store rejects a managed model missing its receipt")

      var wrongReceipt = try QixiNativeModelInstallReceiptStore.receipt(
        forModelAt: repeatInstall.resolvedModel.fileURL,
        spec: tinySpec,
        fileManager: fileManager
      )
      wrongReceipt.sha256HexDigest = String(repeating: "0", count: 64)
      let wrongReceiptData = try JSONEncoder().encode(wrongReceipt)
      try wrongReceiptData.write(to: receiptURL)
      expect(installedStore.resolvedModel(for: tinySpec) == nil, "native model store rejects a managed model with a mismatched receipt")
    } catch {
      fail("native model installer should install a verified tiny model: \(error)")
    }

    let historyA = [
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 15),
      BoardMove(color: .black, x: 16, y: 3),
      BoardMove(color: .white, x: 2, y: 15),
    ]
    let historyB = [
      BoardMove(color: .black, x: 16, y: 3),
      BoardMove(color: .white, x: 2, y: 15),
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 15),
    ]
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: historyB, komi: 7.5, rootNoise: 0.0),
      "position identity distinguishes same stones with different ordered history"
    )
    let identityPhotographedSetup = [
      BoardSetupStone(color: .black, x: 3, y: 3),
      BoardSetupStone(color: .white, x: 15, y: 15),
    ]
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: [], setupStones: identityPhotographedSetup, komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: Array(historyA.prefix(2)), komi: 7.5, rootNoise: 0.0),
      "position identity keeps photographed setup stones distinct from fabricated ordered history"
    )
    expect(
      QixiBoardPosition.visibleStones(after: [], setupStones: identityPhotographedSetup).map(\.id).sorted() ==
        identityPhotographedSetup.map(\.id).sorted(),
      "board replay can render photographed setup stones without inventing moves"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: [BoardMove(pass: .black)], komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: [], komi: 7.5, rootNoise: 0.0),
      "position identity includes pass moves"
    )
    let repeatedCoordinateHistory = [
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(color: .white, x: 0, y: 0),
      BoardMove(color: .black, x: 0, y: 1),
      BoardMove(pass: .white),
      BoardMove(color: .black, x: 0, y: 0),
    ]
    let singleOccupancyHistory = [
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(pass: .white),
      BoardMove(color: .black, x: 0, y: 1),
      BoardMove(pass: .white),
      BoardMove(color: .black, x: 0, y: 0),
    ]
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: repeatedCoordinateHistory, komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: singleOccupancyHistory, komi: 7.5, rootNoise: 0.0),
      "position identity preserves repeated coordinates instead of collapsing to board occupancy"
    )
    let simpleCaptureHistory = [
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(color: .white, x: 0, y: 0),
      BoardMove(color: .black, x: 0, y: 1),
      BoardMove(pass: .white),
    ]
    let simpleCaptureStones = QixiBoardPosition.visibleStones(after: simpleCaptureHistory)
    expect(
      Set(simpleCaptureStones.map(\.id)) == Set([1, 19]) &&
        simpleCaptureStones.allSatisfy { $0.color == .black },
      "board replay removes captured stones from the visible board"
    )
    expect(
      !QixiBoardPosition.isOccupied(after: simpleCaptureHistory, x: 0, y: 0),
      "board replay frees captured coordinates for later history"
    )
    let simpleCaptureBeforeHistory = [
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(color: .white, x: 0, y: 0),
    ]
    expect(
      QixiBoardPosition.isLegalMove(after: simpleCaptureBeforeHistory, x: 0, y: 1, color: .black),
      "board legality allows a move that captures before checking self-liberty"
    )
    let simpleCapturePreviewIDs = QixiBoardPosition.capturedStoneIDsByPlaying(
      BoardMove(color: .black, x: 0, y: 1),
      after: simpleCaptureBeforeHistory
    )
    expect(
      simpleCapturePreviewIDs == [0],
      "next move preview exposes the captured stone for ghosting"
    )
    let multiStoneCaptureHistory = [
      BoardMove(color: .white, x: 1, y: 1),
      BoardMove(color: .white, x: 1, y: 2),
      BoardMove(color: .black, x: 0, y: 1),
      BoardMove(color: .black, x: 2, y: 1),
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(color: .black, x: 0, y: 2),
      BoardMove(color: .black, x: 2, y: 2),
      BoardMove(color: .black, x: 1, y: 3),
    ]
    let multiStoneCaptureStones = QixiBoardPosition.visibleStones(after: multiStoneCaptureHistory)
    expect(
      Set(multiStoneCaptureStones.map(\.id)) == Set([1, 19, 21, 38, 40, 58]) &&
        multiStoneCaptureStones.allSatisfy { $0.color == .black },
      "board replay removes captured multi-stone groups"
    )
    expect(
      !QixiBoardPosition.isOccupied(after: multiStoneCaptureHistory, x: 1, y: 1) &&
        !QixiBoardPosition.isOccupied(after: multiStoneCaptureHistory, x: 1, y: 2),
      "board replay frees every coordinate in a captured group"
    )
    let multiStoneCapturePreviewIDs = QixiBoardPosition.capturedStoneIDsByPlaying(
      BoardMove(color: .black, x: 1, y: 3),
      after: Array(multiStoneCaptureHistory.dropLast())
    )
    expect(
      multiStoneCapturePreviewIDs == [20, 39],
      "next move preview exposes every captured point in a multi-stone group"
    )
    let suicideRollbackHistory = [
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(color: .black, x: 0, y: 1),
      BoardMove(color: .black, x: 2, y: 1),
      BoardMove(color: .black, x: 1, y: 2),
      BoardMove(color: .white, x: 1, y: 1),
    ]
    let suicideRollbackStones = QixiBoardPosition.visibleStones(after: suicideRollbackHistory)
    expect(
      Set(suicideRollbackStones.map(\.id)) == Set([1, 19, 21, 39]) &&
        suicideRollbackStones.allSatisfy { $0.color == .black },
      "board replay rolls back non-capturing suicide moves"
    )
    let suicideBeforeHistory = Array(suicideRollbackHistory.dropLast())
    expect(
      !QixiBoardPosition.isLegalMove(after: suicideBeforeHistory, x: 1, y: 1, color: .white),
      "board legality rejects non-capturing suicide moves before history mutation"
    )
    expect(
      !QixiBoardPosition.isLegalMove(after: suicideBeforeHistory, x: 1, y: 0, color: .white),
      "board legality rejects occupied intersections before history mutation"
    )
    let koBeforeCaptureHistory = [
      BoardMove(color: .black, x: 0, y: 1),
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(color: .black, x: 2, y: 1),
      BoardMove(color: .white, x: 1, y: 1),
      BoardMove(color: .white, x: 0, y: 2),
      BoardMove(color: .white, x: 2, y: 2),
      BoardMove(color: .white, x: 1, y: 3),
    ]
    let koAfterCaptureHistory = koBeforeCaptureHistory + [
      BoardMove(color: .black, x: 1, y: 2),
    ]
    expect(
      !QixiBoardPosition.isLegalMove(after: koAfterCaptureHistory, x: 1, y: 1, color: .white),
      "board legality rejects immediate ko recapture using previous board history"
    )
    expect(
      QixiBoardPosition.isLegalMove(after: koAfterCaptureHistory, x: 3, y: 3, color: .white),
      "board legality still allows non-repeating replies after a ko capture"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: koBeforeCaptureHistory, komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: koAfterCaptureHistory, komi: 7.5, rootNoise: 0.0),
      "position identity keeps ko capture history distinct from its prior board"
    )
    expect(
      QixiBoardPosition.firstIllegalMoveIndex(in: koAfterCaptureHistory + [
        BoardMove(color: .white, x: 1, y: 1),
      ]) == koAfterCaptureHistory.count,
      "imported line validation reports the first illegal ko recapture"
    )
    expect(
      QixiBoardPosition.firstIllegalMoveIndex(in: koAfterCaptureHistory + [
        BoardMove(pass: .white),
        BoardMove(color: .black, x: 3, y: 3),
        BoardMove(color: .white, x: 1, y: 1),
      ]) == nil,
      "imported line validation accepts ko recapture after intervening play"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b18nbt, moves: historyA, komi: 7.5, rootNoise: 0.0),
      "position identity includes engine identity"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0)
        .contains("rules:Chinese"),
      "position identity includes fixed Chinese rules"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 6.5, rootNoise: 0.0),
      "position identity includes komi"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.04),
      "position identity includes root noise"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0000) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0004),
      "position identity preserves sub-millipoint root-noise differences"
    )
    expect(
      QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5000, rootNoise: 0.0) !=
        QixiPositionIdentity.cacheKey(engine: .b6, moves: historyA, komi: 7.5004, rootNoise: 0.0),
      "position identity preserves sub-millipoint komi differences"
    )
    let requestIdentity = QixiAnalysisRequestIdentity(
      engine: .b6,
      moves: historyA,
      komi: 7.5,
      rootNoise: 0.0
    )
    expect(
      requestIdentity.matches(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.0),
      "analysis request identity matches an unchanged engine and position"
    )
    expect(
      !requestIdentity.matches(engine: .b6, moves: historyA, setupStones: identityPhotographedSetup, komi: 7.5, rootNoise: 0.0),
      "analysis request identity rejects stale results after a setup-stone change"
    )
    let setupRequestIdentity = QixiAnalysisRequestIdentity(
      engine: .b6,
      moves: [],
      setupStones: identityPhotographedSetup,
      komi: 7.5,
      rootNoise: 0.0
    )
    expect(
      setupRequestIdentity.matches(engine: .b6, moves: [], setupStones: identityPhotographedSetup, komi: 7.5, rootNoise: 0.0),
      "analysis request identity matches an unchanged photographed setup position"
    )
    expect(
      !setupRequestIdentity.matches(engine: .b6, moves: [], komi: 7.5, rootNoise: 0.0),
      "analysis request identity rejects stale results after photographed setup is cleared"
    )
    expect(
      !requestIdentity.matches(engine: .b18nbt, moves: historyA, komi: 7.5, rootNoise: 0.0),
      "analysis request identity rejects stale results after an engine switch"
    )
    expect(
      !requestIdentity.matches(engine: .b6, moves: historyB, komi: 7.5, rootNoise: 0.0),
      "analysis request identity rejects stale results after an ordered-history change"
    )
    expect(
      !requestIdentity.matches(engine: .b6, moves: repeatedCoordinateHistory, komi: 7.5, rootNoise: 0.0),
      "analysis request identity rejects stale results after a repeated-coordinate history change"
    )
    expect(
      !requestIdentity.matches(engine: .b6, moves: historyA, komi: 6.5, rootNoise: 0.0),
      "analysis request identity rejects stale results after a komi change"
    )
    expect(
      !requestIdentity.matches(engine: .b6, moves: historyA, komi: 7.5, rootNoise: 0.04),
      "analysis request identity rejects stale results after a wide-root-noise change"
    )
    do {
      try assertSharedPositionIdentityFixture()
    } catch {
      fail("shared position identity fixture could not be checked by Swift: \(error)")
    }

    let bridge = QixiNativeKataGoBridge()
    expect(!bridge.isLinked, "smoke build uses the explicit not-linked native bridge")
    do {
      try bridge.loadEngine("")
      fail("raw native bridge must reject an empty engine id")
    } catch {
      let nsError = error as NSError
      expect(nsError.domain == "QixiNativeKataGo", "invalid engine error domain is stable")
      expect(nsError.code == 2, "invalid request code is stable")
    }

    do {
      try bridge.loadEngine(AnalysisEngine.b6.rawValue)
      fail("raw native bridge must require model config before loading b6")
    } catch {
      let nsError = error as NSError
      expect(nsError.domain == "QixiNativeKataGo", "missing model config error domain is stable")
      expect(nsError.code == 2, "missing model config is an invalid request")
    }

    if let spec = QixiNativeModelRegistry.spec(for: .b6) {
      do {
        try bridge.configureModel(
          AnalysisEngine.b6.rawValue,
          resourceName: spec.resourceName,
          modelPath: resolvedB6.fileURL.path,
          coreMLPackagePaths: resolvedB6.coreMLPackageURLs.map(\.path),
          minimumMemoryMB: Int32(spec.minimumMemoryMB),
          recommendedMemoryMB: Int32(spec.recommendedMemoryMB),
          maximumMemoryMB: Int32(spec.maximumMemoryMB)
        )
      } catch {
        fail("native bridge should accept the b6 model spec: \(error)")
      }
    }

    do {
      try bridge.loadEngine(AnalysisEngine.b6.rawValue)
      fail("raw native bridge must report missing library for b6")
    } catch {
      let nsError = error as NSError
      expect(nsError.domain == "QixiNativeKataGo", "bridge error domain is stable")
      expect(nsError.code == 1, "bridge library-not-linked code is stable")
    }

    do {
      _ = try bridge.analyzeRequestJSON("")
      fail("raw native bridge must reject an empty analysis request")
    } catch {
      let nsError = error as NSError
      expect(nsError.domain == "QixiNativeKataGo", "invalid analysis error domain is stable")
      expect(nsError.code == 2, "invalid analysis request code is stable")
    }

    do {
      try bridge.loadEngine(AnalysisEngine.none.rawValue)
      let rawTombstoneURL = tempModelDirectory.appendingPathComponent("raw-native-no-engine-tombstone.json")
      try bridge.exportTombstone(toFile: rawTombstoneURL.path)
      let rawTombstone = try String(contentsOf: rawTombstoneURL, encoding: .utf8)
      expect(
        rawTombstone.contains("\"kind\":\"qixi-native-katago-tombstone\"") &&
          rawTombstone.contains("\"engine\":\"none\""),
        "raw native bridge exports no-engine tombstone JSON"
      )
      try bridge.restoreTombstone(fromFile: rawTombstoneURL.path)
    } catch {
      fail("raw native bridge should export and restore a no-engine tombstone: \(error)")
    }

    do {
      let status = try await nativeService.setEngine(.none)
      expect(
        !status.running &&
          status.engine == AnalysisEngine.none.rawValue &&
          status.engineId == AnalysisEngine.none.rawValue,
        "native none engine is allowed and preserves model-identity status"
      )
      let responseA = try await nativeService.analyze(moves: [], maxVisits: 1, komi: 7.5, rootNoise: 0.0)
      let responseB = try await nativeService.analyze(
        moves: [BoardMove(color: .black, x: 3, y: 3)],
        maxVisits: 1,
        komi: 7.5,
        rootNoise: 0.0
      )
      expect(responseA.engine == "none", "native none analysis response decodes")
      expect(responseA.state == "no engine loaded", "native none analysis state is stable")
      expect(responseA.visits == 0, "native none analysis has zero visits")
      expect(responseA.moves.isEmpty, "native none analysis has no candidate moves")
      expect(responseA.ownership.isEmpty, "native none analysis has no ownership")
      expect(responseA.positionKey != responseB.positionKey, "native none position key changes with request JSON")
      expect(
        responseA.positionKey == QixiPositionIdentity.cacheKey(engine: .none, moves: [], komi: 7.5, rootNoise: 0.0),
        "native none response uses shared semantic position identity"
      )
      async let concurrentA = nativeService.analyze(
        moves: [BoardMove(color: .black, x: 3, y: 3)],
        maxVisits: 1,
        komi: 7.5,
        rootNoise: 0.0
      )
      async let concurrentB = nativeService.analyze(
        moves: [BoardMove(pass: .black)],
        maxVisits: 1,
        komi: 6.5,
        rootNoise: 0.04
      )
      let (parallelA, parallelB) = try await (concurrentA, concurrentB)
      expect(
        parallelA.positionKey == QixiPositionIdentity.cacheKey(
          engine: .none,
          moves: [BoardMove(color: .black, x: 3, y: 3)],
          komi: 7.5,
          rootNoise: 0.0
        ),
        "native actor service serializes concurrent bridge analysis without corrupting the first position key"
      )
      expect(
        parallelB.positionKey == QixiPositionIdentity.cacheKey(
          engine: .none,
          moves: [BoardMove(pass: .black)],
          komi: 6.5,
          rootNoise: 0.04
        ),
        "native actor service serializes concurrent bridge analysis without corrupting the second position key"
      )
    } catch {
      fail("native none engine should not require a linked KataGo library: \(error)")
    }

    do {
      _ = try await nativeService.analyze(moves: [], maxVisits: 0, komi: 7.5, rootNoise: 0.0)
      fail("native service must reject invalid maxVisits before native core request serialization")
    } catch QixiAnalysisInputValidationError.invalidMaxVisits(let value) {
      expect(value == 0, "native service input validation preserves invalid maxVisits diagnostics")
    } catch {
      fail("unexpected invalid maxVisits service error: \(error)")
    }

    do {
      _ = try await nativeService.setEngine(.b6)
      fail("unlinked native b6 must report library-not-linked before model resolution")
    } catch QixiNativeKataGoServiceError.libraryNotLinked {
      expect(true, "unlinked native b6 reports the missing native library before model resolution")
    } catch {
      fail("unexpected unlinked native service error: \(error)")
    }

    let terminalLowMemoryBridge = FakeSwitchNativeKataGoBridge()
    let terminalLowMemoryNativeService = NativeKataGoAnalysisService(
      bridge: terminalLowMemoryBridge,
      modelStore: testStore,
      memoryPolicy: constrainedMemoryPolicy
    )
    do {
      _ = try await terminalLowMemoryNativeService.setEngine(.b6)
      fail("native b6 must refuse to load when the device memory budget is too small")
    } catch QixiNativeKataGoServiceError.insufficientDeviceMemory(let report) {
      expect(
        report.engine == .b6 && report.availableMemoryMB < report.minimumMemoryMB,
        "native insufficient-memory error includes the model budget report"
      )
    } catch {
      fail("unexpected low-memory native service error: \(error)")
    }

    let installedNativeService = NativeKataGoAnalysisService(
      modelStore: QixiNativeModelStore(additionalSearchDirectories: [tempModelDirectory])
    )
    do {
      _ = try await installedNativeService.setEngine(.b6)
      fail("installed native b6 must not silently fall back without a linked KataGo library")
    } catch QixiNativeKataGoServiceError.libraryNotLinked {
      print("Analysis service smoke passed")
    } catch {
      fail("unexpected native service error: \(error)")
    }
  }

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fail(message)
    }
  }

  static func expectThrows(_ message: String, _ body: () throws -> Void) {
    do {
      try body()
      fail("expected throw for \(message)")
    } catch {
      return
    }
  }

  static func dataByReplacingFirst(in data: Data, _ needle: String, _ replacement: String) -> Data {
    guard let text = String(data: data, encoding: .utf8) else {
      fail("test fixture data is not UTF-8")
    }
    guard let range = text.range(of: needle) else {
      fail("test fixture data is missing \(needle)")
    }
    return Data((text[..<range.lowerBound] + replacement + text[range.upperBound...]).utf8)
  }

  static func assertSharedPositionIdentityFixture() throws {
    guard let fixturePath = ProcessInfo.processInfo.environment["QIXI_POSITION_IDENTITY_FIXTURE"] else {
      fail("QIXI_POSITION_IDENTITY_FIXTURE must point at the shared position identity fixture")
    }
    let fixtureURL = URL(fileURLWithPath: fixturePath)
    let fixture = try JSONDecoder().decode(
      SharedPositionIdentityFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
    expect(fixture.schemaVersion == 2, "shared position identity fixture schema is current")

    var keysByID: [String: String] = [:]
    var visibleStonesByID: [String: [String]] = [:]
    var nextPlayerByID: [String: String] = [:]
    for testCase in fixture.cases {
      guard testCase.rules == QixiPositionIdentity.fixedRules else {
        fail("shared position identity fixture case \(testCase.id) uses unsupported rules \(testCase.rules)")
      }
      guard let engine = AnalysisEngine(rawValue: testCase.engine) else {
        fail("shared position identity fixture case \(testCase.id) uses unknown Swift engine \(testCase.engine)")
      }
      let moves = testCase.moves.map { $0.boardMove(caseID: testCase.id) }
      keysByID[testCase.id] = QixiPositionIdentity.cacheKey(
        engine: engine,
        moves: moves,
        komi: testCase.komi,
        rootNoise: testCase.rootNoise
      )
      visibleStonesByID[testCase.id] = normalizedVisibleStones(after: moves)
      nextPlayerByID[testCase.id] = nextPlayer(after: moves).rawValue
    }

    for relation in fixture.relations {
      guard let left = keysByID[relation.left], let right = keysByID[relation.right] else {
        fail("shared position identity fixture relation \(relation.id) references a missing case")
      }
      guard let leftVisible = visibleStonesByID[relation.left], let rightVisible = visibleStonesByID[relation.right] else {
        fail("shared position identity fixture relation \(relation.id) references a missing visible-stone case")
      }
      guard let leftNextPlayer = nextPlayerByID[relation.left], let rightNextPlayer = nextPlayerByID[relation.right] else {
        fail("shared position identity fixture relation \(relation.id) references a missing next-player case")
      }
      expect(
        (left == right) == relation.equal,
        "Swift shared position identity fixture relation \(relation.id) matches expected partition: \(relation.reason)"
      )
      expect(
        (leftVisible == rightVisible) == relation.sameVisibleStones,
        "Swift shared position identity fixture relation \(relation.id) matches expected visible stones: \(relation.reason)"
      )
      expect(
        (leftNextPlayer == rightNextPlayer) == relation.sameNextPlayer,
        "Swift shared position identity fixture relation \(relation.id) matches expected next player: \(relation.reason)"
      )
    }
  }

  static func normalizedVisibleStones(after moves: [BoardMove]) -> [String] {
    QixiBoardPosition.visibleStones(after: moves)
      .map { "\($0.color.rawValue):\($0.x):\($0.y)" }
      .sorted()
  }

  static func nextPlayer(after moves: [BoardMove]) -> StoneColor {
    guard let last = moves.last else { return .black }
    return last.color == .black ? .white : .black
  }

  static func isExcludedFromBackup(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
  }

  static func fail(_ message: String) -> Never {
    fputs("Analysis service smoke failed: \(message)\n", stderr)
    exit(1)
  }
}
