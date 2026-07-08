import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

struct QixiRealDeviceEvidence: Codable, Equatable {
  static let currentSchemaVersion = 6
  static let currentKind = "qixi-real-device-evidence"

  var schemaVersion: Int = QixiRealDeviceEvidence.currentSchemaVersion
  var kind: String = QixiRealDeviceEvidence.currentKind
  var runId: String
  var recordedAt: Date
  var device: Device
  var app: App
  var backend: Backend?
  var analysis: Analysis
  var measurements: Measurements
  var lifecycle: Lifecycle
  var features: Features
  var artifacts: [Artifact]

  struct Device: Codable, Equatable {
    var idiom: String
    var model: String
    var osVersion: String
    var simulator: Bool
  }

  struct App: Codable, Equatable {
    var bundleIdentifier: String
    var version: String
    var build: String
    var analysisRuntime: String
    var executableSHA256HexDigest: String

    static func current(analysisRuntime: String, bundle: Bundle = .main, executableURL: URL? = nil) -> App {
      let digestURL = executableURL ?? bundle.executableURL
      let executableDigest = digestURL.flatMap { try? QixiNativeModelIntegrity.sha256HexDigest(of: $0) } ?? ""
      return App(
        bundleIdentifier: bundle.bundleIdentifier ??
          bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String ??
          "com.qixi.localanalysis",
        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        analysisRuntime: analysisRuntime,
        executableSHA256HexDigest: executableDigest
      )
    }
  }

  struct Backend: Codable, Equatable {
    var url: String
    var status: BackendStatus
  }

  struct BackendStatus: Codable, Equatable {
    var engine: String
    var engineId: String
    var state: String
    var running: Bool
    var paused: Bool
  }

  struct Analysis: Codable, Equatable {
    var engineId: AnalysisEngine
    var realModel: Bool
    var visits: Int
    var candidateCount: Int
    var ownershipSource: String
    var positionIdentity: PositionIdentity
    var nativeEngine: NativeEngine?
  }

  struct PositionIdentity: Codable, Equatable {
    var currentPositionKey: String
    var sameVisibleStones: Bool
    var sameVisibleHistoryAKey: String
    var sameVisibleHistoryBKey: String
    var sameVisibleHistoryKeysDistinct: Bool
  }

  struct NativeEngine: Codable, Equatable {
    struct CoreMLPackage: Codable, Equatable {
      var resourceName: String
      var variantID: String
      var fileCount: Int
      var totalByteCount: UInt64
      var sha256TreeDigest: String
    }

    var modelDigestVerified: Bool
    var engineId: AnalysisEngine
    var modelResourceName: String
    var modelByteCount: UInt64
    var modelSHA256HexDigest: String
    var coreMLPackages: [CoreMLPackage]
    var tombstoneExported: Bool
    var tombstoneFilename: String
    var tombstoneExportedAt: Date
    var tombstoneRestored: Bool
    var tombstoneRestoredAt: Date
  }

  struct Measurements: Codable, Equatable {
    var launch: Launch
    var memory: Memory
    var framePacing: FramePacing
  }

  struct Launch: Codable, Equatable {
    var coldLaunchMs: Int
    var visualReadyMs: Int
  }

  struct Memory: Codable, Equatable {
    var peakRSSMB: Double
    var postAnalysisRSSMB: Double
  }

  struct FramePacing: Codable, Equatable {
    var targetRefreshHz: Int
    var observedRefreshHz: Double
    var droppedFramePercent: Double
  }

  struct Lifecycle: Codable, Equatable {
    var backgroundedSeconds: Int
    var autosaveWritten: Bool
    var tombstoneWritten: Bool
    var restoredLatestState: Bool
  }

  struct Features: Codable, Equatable {
    var cameraRecognitionTested: Bool
    var iCloudSyncTested: Bool
    var modelImportTested: Bool
  }

  struct Artifact: Codable, Equatable {
    var kind: String
    var path: String
    var byteCount: UInt64
    var sha256HexDigest: String
  }
}

struct QixiRealDeviceEvidenceExportAudit: Codable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int = QixiRealDeviceEvidenceExportAudit.currentSchemaVersion
  var recordedAt: Date
  var status: String
  var evidenceFilename: String?
  var error: String?
}

enum QixiRealDeviceEvidenceValidationError: Error, Equatable, LocalizedError {
  case invalidSchema(Int)
  case invalidKind(String)
  case simulatorEvidence
  case invalidDevice(String)
  case invalidAppRuntime(String)
  case missingBackend
  case invalidBackendURL(String)
  case invalidBackendStatus(String)
  case invalidAnalysis(String)
  case invalidMeasurements(String)
  case invalidLifecycle(String)
  case invalidFeatures(String)
  case missingArtifactKinds([String])
  case invalidArtifact(String)

  var errorDescription: String? {
    switch self {
    case .invalidSchema(let schema):
      return "Real-device evidence schemaVersion \(schema) is not supported."
    case .invalidKind(let kind):
      return "Real-device evidence kind \(kind) is not supported."
    case .simulatorEvidence:
      return "Real-device evidence must come from a physical iPad or iPhone."
    case .invalidDevice(let message),
      .invalidAppRuntime(let message),
      .invalidBackendURL(let message),
      .invalidBackendStatus(let message),
      .invalidAnalysis(let message),
      .invalidMeasurements(let message),
      .invalidLifecycle(let message),
      .invalidFeatures(let message),
      .invalidArtifact(let message):
      return message
    case .missingBackend:
      return "HTTP bridge real-device evidence must include backend status."
    case .missingArtifactKinds(let kinds):
      return "Real-device evidence is missing artifact kinds: \(kinds.joined(separator: ", "))."
    }
  }
}

enum QixiRealDeviceEvidenceStore {
  static let evidenceFilename = "real-device-evidence.qixi-release.json"
  static let exportAuditFilename = "real-device-evidence.export.json"
  static let maxEvidenceBytes = 1 * 1024 * 1024
  static let maxExportAuditBytes = 64 * 1024
  static let maxScreenshotArtifactBytes = 64 * 1024 * 1024
  static let maxPerformanceArtifactBytes = 1 * 1024 * 1024
  static let maxDeviceLogArtifactBytes = 1 * 1024 * 1024
  static let requiredArtifactKinds: Set<String> = ["screenshot", "performance", "device-log"]
  static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  static let iPadMinimumScreenshotSize = (width: 1000, height: 700)
  static let iPhoneMinimumScreenshotSize = (width: 800, height: 350)
  static let minimumScreenshotVisualVariance = 12.0
  static let minimumScreenshotDarkPixelRatio = 1.0 / 1000.0
  static let minimumScreenshotDarkPixels = 800
  static let maxScreenshotPixels = 16 * 1024 * 1024
  private static let pngHeaderByteCount = 33
  static let performanceArtifactKind = "qixi-real-device-performance"
  static let performanceArtifactSchemaVersion = 1
  static let deviceLogArtifactSchemaVersion = 1
  static let reservedArtifactFilenames: Set<String> = [evidenceFilename, exportAuditFilename]
  static let validPerformanceArtifactSources: Set<String> = ["instruments", "xctrace", "metricKit"]
  static let maximumEvidenceAge: TimeInterval = 7 * 24 * 60 * 60
  static let futureEvidenceClockSkew: TimeInterval = 5 * 60
  static let artifactRecordedAtTolerance: TimeInterval = 1
  static let maximumStagedArtifactAge: TimeInterval = 24 * 60 * 60
  static let maximumNativeTombstoneAuditAge: TimeInterval = 24 * 60 * 60

  static var evidenceURL: URL {
    QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(evidenceFilename, isDirectory: false)
  }

  static var exportAuditURL: URL {
    QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(exportAuditFilename, isDirectory: false)
  }

  static func save(_ evidence: QixiRealDeviceEvidence, to url: URL = evidenceURL) throws {
    try validateEvidenceOutputURL(url)
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: url.deletingLastPathComponent(),
      label: "Real-device evidence directory"
    )
    try validateEvidenceOutputURL(url)
    try rejectSymbolicLinkComponents(in: url, label: "Real-device evidence path")
    try validate(evidence, evidenceURL: url)
    let data = try encodeUnchecked(evidence)
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: url,
      label: "Real-device evidence path"
    )
    try markExported(evidenceURL: url)
  }

  static func encode(_ evidence: QixiRealDeviceEvidence, evidenceURL: URL? = nil) throws -> Data {
    try validate(evidence, evidenceURL: evidenceURL)
    return try encodeUnchecked(evidence)
  }

  static func validateEvidenceOutputURL(_ url: URL) throws {
    guard !url.hasDirectoryPath else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Real-device evidence output path must name a JSON file: \(url.path)"
      )
    }
    guard !url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          url.pathExtension.lowercased() == "json" else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Real-device evidence output path must name a JSON file: \(url.path)"
      )
    }
    guard url.lastPathComponent != exportAuditFilename else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Real-device evidence output path must not use the export audit filename: \(url.path)"
      )
    }
    try rejectSymbolicLinkComponents(in: url, label: "Real-device evidence path")
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Real-device evidence output path must not be a symbolic link: \(url.path)"
      )
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
       isDirectory.boolValue || values?.isRegularFile != true {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Real-device evidence output path must be a regular JSON file: \(url.path)"
      )
    }
  }

  private static func encodeUnchecked(_ evidence: QixiRealDeviceEvidence) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(evidence)
  }

  static func decode(_ data: Data) throws -> QixiRealDeviceEvidence? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      data,
      label: "Qixi real-device evidence",
      maxBytes: maxEvidenceBytes
    )
    return try decodeValidatedObjectData(objectData)
  }

  private static func decodeValidatedObjectData(_ objectData: Data) throws -> QixiRealDeviceEvidence? {
    if evidenceHasMixedRuntimeKeys(objectData) {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let evidence = try decoder.decode(QixiRealDeviceEvidence.self, from: objectData)
    guard evidence.schemaVersion == QixiRealDeviceEvidence.currentSchemaVersion else { return nil }
    guard evidence.kind == QixiRealDeviceEvidence.currentKind else { return nil }
    guard (try? validate(evidence, evidenceURL: nil)) != nil else { return nil }
    return evidence
  }

  private static func evidenceHasMixedRuntimeKeys(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let app = object["app"] as? [String: Any],
          let runtime = app["analysisRuntime"] as? String else {
      return false
    }
    if runtime == "nativeInProcess" {
      return object.keys.contains("backend")
    }
    if runtime == "httpBridge",
       let analysis = object["analysis"] as? [String: Any] {
      return analysis.keys.contains("nativeEngine")
    }
    return false
  }

  static func load(from url: URL = evidenceURL) -> QixiRealDeviceEvidence? {
    guard (try? rejectSymbolicLinkComponents(in: url, label: "Real-device evidence path")) != nil else {
      return nil
    }
    guard let objectData = try? QixiStrictJSONDocumentValidator.validatedObjectData(
      from: url,
      label: "Qixi real-device evidence",
      maxBytes: maxEvidenceBytes
    ) else { return nil }
    return try? decodeValidatedObjectData(objectData)
  }

  static func markExported(evidenceURL: URL, recordedAt: Date = Date()) throws {
    try saveExportAudit(
      QixiRealDeviceEvidenceExportAudit(
        recordedAt: recordedAt,
        status: "exported",
        evidenceFilename: evidenceURL.lastPathComponent,
        error: nil
      )
    )
  }

  static func markExportFailed(error: Error, evidenceURL: URL = evidenceURL, recordedAt: Date = Date()) {
    let audit = QixiRealDeviceEvidenceExportAudit(
      recordedAt: recordedAt,
      status: "failed",
      evidenceFilename: evidenceURL.lastPathComponent,
      error: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    )
    try? saveExportAudit(audit)
  }

  static func loadExportAudit(from url: URL = exportAuditURL) -> QixiRealDeviceEvidenceExportAudit? {
    guard (try? rejectSymbolicLinkComponents(in: url, label: "Real-device evidence export audit path")) != nil else {
      return nil
    }
    guard let objectData = try? QixiStrictJSONDocumentValidator.validatedObjectData(
      from: url,
      label: "Qixi real-device evidence export audit",
      maxBytes: maxExportAuditBytes
    ) else { return nil }
    return try? decodeValidatedExportAudit(objectData)
  }

  static func encode(_ audit: QixiRealDeviceEvidenceExportAudit) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(audit)
  }

  static func decodeExportAudit(_ data: Data) throws -> QixiRealDeviceEvidenceExportAudit? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      data,
      label: "Qixi real-device evidence export audit",
      maxBytes: maxExportAuditBytes
    )
    return try decodeValidatedExportAudit(objectData)
  }

  private static func decodeValidatedExportAudit(_ objectData: Data) throws -> QixiRealDeviceEvidenceExportAudit? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let audit = try decoder.decode(QixiRealDeviceEvidenceExportAudit.self, from: objectData)
    guard audit.schemaVersion == QixiRealDeviceEvidenceExportAudit.currentSchemaVersion else { return nil }
    guard ["exported", "failed"].contains(audit.status) else { return nil }
    return audit
  }

  private static func saveExportAudit(_ audit: QixiRealDeviceEvidenceExportAudit) throws {
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: exportAuditURL.deletingLastPathComponent(),
      label: "Real-device evidence export audit directory"
    )
    try rejectSymbolicLinkComponents(in: exportAuditURL, label: "Real-device evidence export audit path")
    let data = try encode(audit)
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: exportAuditURL,
      label: "Real-device evidence export audit path"
    )
  }

  static func analysisEvidence(
    engine: AnalysisEngine,
    cachedAnalysis: QixiCachedAnalysis,
    komi: Double = QixiAnalysisLimits.defaultKomi,
    rootNoise: Double = QixiAnalysisLimits.defaultRootNoise,
    nativeEngine: QixiRealDeviceEvidence.NativeEngine? = nil
  ) -> QixiRealDeviceEvidence.Analysis {
    QixiRealDeviceEvidence.Analysis(
      engineId: engine,
      realModel: engine != .none,
      visits: cachedAnalysis.visits,
      candidateCount: cachedAnalysis.candidates.count,
      ownershipSource: "mcts",
      positionIdentity: positionIdentityEvidence(
        engine: engine,
        cachedAnalysis: cachedAnalysis,
        komi: komi,
        rootNoise: rootNoise
      ),
      nativeEngine: nativeEngine
    )
  }

  static func positionIdentityEvidence(
    engine: AnalysisEngine,
    cachedAnalysis: QixiCachedAnalysis,
    komi: Double,
    rootNoise: Double
  ) -> QixiRealDeviceEvidence.PositionIdentity {
    let sameVisibleHistoryA = [
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 15),
      BoardMove(color: .black, x: 16, y: 3),
      BoardMove(color: .white, x: 2, y: 15)
    ]
    let sameVisibleHistoryB = [
      BoardMove(color: .black, x: 16, y: 3),
      BoardMove(color: .white, x: 2, y: 15),
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 15)
    ]
    func sortedVisibleStones(_ stones: [VisibleBoardStone]) -> [VisibleBoardStone] {
      stones.sorted { lhs, rhs in
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        return lhs.color.rawValue < rhs.color.rawValue
      }
    }
    let visibleA = sortedVisibleStones(QixiBoardPosition.visibleStones(after: sameVisibleHistoryA))
    let visibleB = sortedVisibleStones(QixiBoardPosition.visibleStones(after: sameVisibleHistoryB))
    let keyA = QixiPositionIdentity.cacheKey(
      engine: engine,
      moves: sameVisibleHistoryA,
      komi: komi,
      rootNoise: rootNoise
    )
    let keyB = QixiPositionIdentity.cacheKey(
      engine: engine,
      moves: sameVisibleHistoryB,
      komi: komi,
      rootNoise: rootNoise
    )
    return QixiRealDeviceEvidence.PositionIdentity(
      currentPositionKey: cachedAnalysis.positionKey,
      sameVisibleStones: visibleA == visibleB,
      sameVisibleHistoryAKey: keyA,
      sameVisibleHistoryBKey: keyB,
      sameVisibleHistoryKeysDistinct: keyA != keyB
    )
  }

  static func validate(_ evidence: QixiRealDeviceEvidence, evidenceURL: URL?) throws {
    guard evidence.schemaVersion == QixiRealDeviceEvidence.currentSchemaVersion else {
      throw QixiRealDeviceEvidenceValidationError.invalidSchema(evidence.schemaVersion)
    }
    guard evidence.kind == QixiRealDeviceEvidence.currentKind else {
      throw QixiRealDeviceEvidenceValidationError.invalidKind(evidence.kind)
    }
    try validate(runId: evidence.runId)
    try validate(recordedAt: evidence.recordedAt)
    try validate(device: evidence.device)
    try validate(app: evidence.app)
    try validate(backend: evidence.backend, runtime: evidence.app.analysisRuntime, analysis: evidence.analysis)
    try validate(analysis: evidence.analysis, runtime: evidence.app.analysisRuntime, recordedAt: evidence.recordedAt)
    try validate(measurements: evidence.measurements)
    try validateNativeMemoryBudget(
      measurements: evidence.measurements,
      runtime: evidence.app.analysisRuntime,
      engineId: evidence.analysis.engineId
    )
    try validate(lifecycle: evidence.lifecycle)
    try validate(features: evidence.features)
    try validate(artifacts: evidence.artifacts, evidenceURL: evidenceURL, evidence: evidence)
  }

  private static func validate(device: QixiRealDeviceEvidence.Device) throws {
    guard !device.idiom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !device.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !device.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw QixiRealDeviceEvidenceValidationError.invalidDevice("Device evidence fields must be non-empty.")
    }
    guard device.idiom == "iPad" || device.idiom == "iPhone" else {
      throw QixiRealDeviceEvidenceValidationError.invalidDevice("Device idiom must be iPad or iPhone.")
    }
    guard !device.simulator && !device.model.lowercased().contains("simulator") else {
      throw QixiRealDeviceEvidenceValidationError.simulatorEvidence
    }
  }

  private static func validate(runId: String) throws {
    let bytes = Array(runId.utf8)
    let hyphenIndexes: Set<Int> = [8, 13, 18, 23]
    guard bytes.count == 36 else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Real-device evidence runId must be a canonical lowercase UUID."
      )
    }
    for (index, byte) in bytes.enumerated() {
      if hyphenIndexes.contains(index) {
        guard byte == 45 else {
          throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
            "Real-device evidence runId must be a canonical lowercase UUID."
          )
        }
      } else {
        let isDigit = byte >= 48 && byte <= 57
        let isLowercaseHex = byte >= 97 && byte <= 102
        guard isDigit || isLowercaseHex else {
          throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
            "Real-device evidence runId must be a canonical lowercase UUID."
          )
        }
      }
    }
  }

  private static func validate(recordedAt: Date, now: Date = Date()) throws {
    guard recordedAt.timeIntervalSince(now) <= futureEvidenceClockSkew else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Real-device evidence recordedAt must not be in the future beyond the release evidence clock-skew budget."
      )
    }
    guard now.timeIntervalSince(recordedAt) <= maximumEvidenceAge else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Real-device evidence recordedAt is too old for release evidence."
      )
    }
  }

  private static func isLowercaseSHA256HexDigest(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { byte in
      (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
  }

  private static func validate(app: QixiRealDeviceEvidence.App) throws {
    guard !app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !app.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !app.build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw QixiRealDeviceEvidenceValidationError.invalidAppRuntime("App evidence fields must be non-empty.")
    }
    guard Self.isLowercaseSHA256HexDigest(app.executableSHA256HexDigest) else {
      throw QixiRealDeviceEvidenceValidationError.invalidAppRuntime(
        "App executableSHA256HexDigest must be a lowercase SHA-256 hex digest."
      )
    }
  }

  private static func validate(
    backend: QixiRealDeviceEvidence.Backend?,
    runtime: String,
    analysis: QixiRealDeviceEvidence.Analysis
  ) throws {
    #if QIXI_NATIVE_RELEASE
    guard runtime == "nativeInProcess" else {
      throw QixiRealDeviceEvidenceValidationError.invalidAppRuntime(
        "NativeRelease evidence must use nativeInProcess."
      )
    }
    if backend != nil {
      throw QixiRealDeviceEvidenceValidationError.invalidBackendURL(
        "Native in-process evidence must omit backend entirely."
      )
    }
    #else
    switch runtime {
    case "httpBridge":
      guard let backend else { throw QixiRealDeviceEvidenceValidationError.missingBackend }
      try validateBackendURL(backend.url)
      guard ["ready", "running", "paused"].contains(backend.status.state) else {
        throw QixiRealDeviceEvidenceValidationError.invalidBackendStatus(
          "Backend status state must be ready, running, or paused."
        )
      }
      guard !backend.status.engine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !backend.status.engineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw QixiRealDeviceEvidenceValidationError.invalidBackendStatus("Backend engine fields must be non-empty.")
      }
      let expectedBackendEngine = "katago-metal-mux:\(analysis.engineId.rawValue)"
      guard backend.status.engine == expectedBackendEngine else {
        throw QixiRealDeviceEvidenceValidationError.invalidBackendStatus(
          "Backend status engine must match \(expectedBackendEngine)."
        )
      }
      guard backend.status.engineId == analysis.engineId.rawValue else {
        throw QixiRealDeviceEvidenceValidationError.invalidBackendStatus(
          "Backend status engineId must match analysis engineId."
        )
      }
    case "nativeInProcess":
      if backend != nil {
        throw QixiRealDeviceEvidenceValidationError.invalidBackendURL(
          "Native in-process evidence must omit backend entirely."
        )
      }
    default:
      throw QixiRealDeviceEvidenceValidationError.invalidAppRuntime(
        "App analysis runtime must be httpBridge or nativeInProcess."
      )
    }
    #endif
  }

  #if !QIXI_NATIVE_RELEASE
  private static func validateBackendURL(_ rawURL: String) throws {
    guard let components = URLComponents(string: rawURL),
          let scheme = components.scheme,
          ["http", "https"].contains(scheme),
          let host = components.host,
          !host.isEmpty else {
      throw QixiRealDeviceEvidenceValidationError.invalidBackendURL("Backend URL must be an HTTP origin.")
    }
    let normalizedHost = host.lowercased()
    let forbiddenHosts = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
    guard !forbiddenHosts.contains(normalizedHost) && !normalizedHost.hasSuffix(".localhost") else {
      throw QixiRealDeviceEvidenceValidationError.invalidBackendURL(
        "Backend URL must use the Mac LAN address, not localhost or loopback."
      )
    }
    guard components.path.isEmpty || components.path == "/" else {
      throw QixiRealDeviceEvidenceValidationError.invalidBackendURL("Backend URL must be the origin, not an endpoint.")
    }
  }
  #endif

  private static func validate(
    analysis: QixiRealDeviceEvidence.Analysis,
    runtime: String,
    recordedAt: Date
  ) throws {
    guard analysis.engineId != .none && analysis.realModel else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis("Evidence must use a real KataGo model.")
    }
    guard analysis.visits > 0 else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis("Evidence analysis visits must be positive.")
    }
    guard analysis.candidateCount > 0 && analysis.candidateCount <= QixiBoardPosition.boardSize * QixiBoardPosition.boardSize else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis("Evidence candidate count is outside the board range.")
    }
    guard analysis.ownershipSource == "mcts" else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis("Evidence ownership source must be mcts.")
    }
    try validate(positionIdentity: analysis.positionIdentity)
    if runtime == "nativeInProcess" {
      guard let nativeEngine = analysis.nativeEngine,
            nativeEngine.modelDigestVerified,
            nativeEngine.tombstoneExported,
            nativeEngine.tombstoneRestored else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "Native in-process evidence must prove model digest, tombstone export, and tombstone restore."
        )
      }
      guard let spec = QixiNativeModelRegistry.spec(for: analysis.engineId) else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "Native in-process evidence must name a supported engine model."
        )
      }
      guard nativeEngine.engineId == analysis.engineId else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "Native in-process evidence nativeEngine.engineId must match analysis.engineId."
        )
      }
      guard nativeEngine.modelResourceName == spec.resourceName,
            nativeEngine.modelByteCount == spec.expectedByteCount,
            nativeEngine.modelSHA256HexDigest == spec.sha256HexDigest else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "Native in-process evidence model digest metadata must match the engine manifest."
        )
      }
      guard nativeEngine.coreMLPackages.count == spec.coreMLPackages.count else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "Native in-process evidence CoreML package metadata must match the engine manifest."
        )
      }
      for (index, packageSpec) in spec.coreMLPackages.enumerated() {
        let packageEvidence = nativeEngine.coreMLPackages[index]
        guard packageEvidence.resourceName == packageSpec.resourceName,
              packageEvidence.variantID == packageSpec.variantID,
              packageEvidence.fileCount == packageSpec.expectedFileCount,
              packageEvidence.totalByteCount == packageSpec.expectedTotalByteCount,
              packageEvidence.sha256TreeDigest == packageSpec.sha256TreeDigest else {
          throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
            "Native in-process evidence CoreML package metadata must match the engine manifest."
          )
        }
      }
      guard nativeEngine.tombstoneFilename == QixiEngineTombstoneStore.tombstoneFilename else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "Native in-process evidence tombstone filename must match the native tombstone store."
        )
      }
      try validateNativeAuditDate(
        nativeEngine.tombstoneExportedAt,
        recordedAt: recordedAt,
        label: "tombstone export"
      )
      try validateNativeAuditDate(
        nativeEngine.tombstoneRestoredAt,
        recordedAt: recordedAt,
        label: "tombstone restore"
      )
    } else if runtime == "httpBridge" {
      guard analysis.nativeEngine == nil else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "HTTP bridge evidence must not include native engine fields."
        )
      }
    }
  }

  private static func validate(positionIdentity: QixiRealDeviceEvidence.PositionIdentity) throws {
    let currentKey = positionIdentity.currentPositionKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyA = positionIdentity.sameVisibleHistoryAKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyB = positionIdentity.sameVisibleHistoryBKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !currentKey.isEmpty,
          !keyA.isEmpty,
          !keyB.isEmpty,
          currentKey.count <= 4096,
          keyA.count <= 4096,
          keyB.count <= 4096 else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Evidence position identity keys must be non-empty and bounded."
      )
    }
    guard positionIdentity.sameVisibleStones else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Evidence position identity must prove the fixture histories have identical visible stones."
      )
    }
    guard positionIdentity.sameVisibleHistoryKeysDistinct,
          keyA != keyB else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Evidence position identity must prove same-visible-stones histories keep distinct position keys."
      )
    }
  }

  private static func validateNativeAuditDate(_ auditDate: Date, recordedAt: Date, label: String) throws {
    guard auditDate <= recordedAt else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process evidence \(label) audit must not be newer than the evidence record."
      )
    }
    guard recordedAt.timeIntervalSince(auditDate) <= maximumNativeTombstoneAuditAge else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process evidence \(label) audit is too old for release evidence."
      )
    }
  }

  private static func validate(measurements: QixiRealDeviceEvidence.Measurements) throws {
    guard measurements.launch.coldLaunchMs > 0,
          measurements.launch.visualReadyMs >= measurements.launch.coldLaunchMs else {
      throw QixiRealDeviceEvidenceValidationError.invalidMeasurements("Launch measurements are invalid.")
    }
    guard measurements.memory.peakRSSMB > 0,
          measurements.memory.postAnalysisRSSMB > 0,
          measurements.memory.postAnalysisRSSMB <= measurements.memory.peakRSSMB else {
      throw QixiRealDeviceEvidenceValidationError.invalidMeasurements("Memory measurements are invalid.")
    }
    let targetHz = measurements.framePacing.targetRefreshHz
    guard targetHz == 60 || targetHz == 120 else {
      throw QixiRealDeviceEvidenceValidationError.invalidMeasurements("Target refresh rate must be 60 or 120 Hz.")
    }
    let minimumObserved = targetHz == 120 ? 110.0 : 55.0
    guard measurements.framePacing.observedRefreshHz >= minimumObserved,
          measurements.framePacing.droppedFramePercent >= 0,
          measurements.framePacing.droppedFramePercent <= 5 else {
      throw QixiRealDeviceEvidenceValidationError.invalidMeasurements("Frame pacing measurements are outside budget.")
    }
  }

  private static func validateNativeMemoryBudget(
    measurements: QixiRealDeviceEvidence.Measurements,
    runtime: String,
    engineId: AnalysisEngine
  ) throws {
    guard runtime == "nativeInProcess" else { return }
    guard let spec = QixiNativeModelRegistry.spec(for: engineId) else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process evidence must name a supported engine model."
      )
    }
    let maximumMemoryMB = Double(spec.maximumMemoryMB)
    guard measurements.memory.peakRSSMB <= maximumMemoryMB,
          measurements.memory.postAnalysisRSSMB <= maximumMemoryMB else {
      throw QixiRealDeviceEvidenceValidationError.invalidMeasurements(
        "Native in-process memory measurements must not exceed \(engineId.rawValue) manifest maximumMemoryMB \(spec.maximumMemoryMB)."
      )
    }
  }

  private static func validate(lifecycle: QixiRealDeviceEvidence.Lifecycle) throws {
    guard lifecycle.backgroundedSeconds > 0,
          lifecycle.autosaveWritten,
          lifecycle.tombstoneWritten,
          lifecycle.restoredLatestState else {
      throw QixiRealDeviceEvidenceValidationError.invalidLifecycle(
        "Lifecycle evidence must prove background, autosave, tombstone, and restore behavior."
      )
    }
  }

  private static func validate(features: QixiRealDeviceEvidence.Features) throws {
    guard features.cameraRecognitionTested,
          features.iCloudSyncTested,
          features.modelImportTested else {
      throw QixiRealDeviceEvidenceValidationError.invalidFeatures(
        "Feature evidence must cover camera recognition, iCloud sync, and model import."
      )
    }
  }

  private static func validate(
    artifacts: [QixiRealDeviceEvidence.Artifact],
    evidenceURL: URL?,
    evidence: QixiRealDeviceEvidence
  ) throws {
    var seenKinds = Set<String>()
    var seenPathsByKind = [String: String]()
    let baseURL = evidenceURL?.deletingLastPathComponent()
    for artifact in artifacts {
      let kind = artifact.kind.trimmingCharacters(in: .whitespacesAndNewlines)
      let rawArtifactPath = artifact.path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !kind.isEmpty,
            !rawArtifactPath.isEmpty else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Artifact kind and path must be non-empty.")
      }
      guard requiredArtifactKinds.contains(kind) else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Artifact kind is unsupported: \(kind)")
      }
      guard !seenKinds.contains(kind) else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Artifact kind is duplicated: \(kind)")
      }
      seenKinds.insert(kind)
      let portablePath = try portableArtifactPath(rawArtifactPath)
      try rejectReservedArtifactPath(portablePath, evidenceURL: evidenceURL)
      if let existingKind = seenPathsByKind[portablePath.normalized] {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Artifact path is duplicated: \(portablePath.normalized) for kinds \(existingKind) and \(kind)"
        )
      }
      seenPathsByKind[portablePath.normalized] = kind
      guard let baseURL else { continue }
      let artifactURL = try regularArtifactFileURL(baseURL: baseURL, portablePath: portablePath)
      let actualByteCount = try QixiNativeModelIntegrity.byteCount(of: artifactURL)
      guard actualByteCount > 0 else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Artifact file is empty: \(artifactURL.path)")
      }
      try validateArtifactByteBudget(kind: kind, artifactURL: artifactURL, actualByteCount: actualByteCount)
      let validatedFingerprint = try validateArtifactFingerprint(
        artifact,
        kind: kind,
        artifactURL: artifactURL,
        actualByteCount: actualByteCount
      )
      let contentFingerprint = try validateArtifactContent(
        kind: kind,
        artifactURL: artifactURL,
        evidence: evidence
      )
      if let contentFingerprint,
         contentFingerprint != validatedFingerprint {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Artifact \(kind) content bytes must match recorded fingerprint: \(artifactURL.path)"
        )
      }
      try validateArtifactFingerprintStableAfterContent(
        artifact,
        kind: kind,
        artifactURL: artifactURL,
        expectedFingerprint: validatedFingerprint
      )
    }
    let missing = requiredArtifactKinds.subtracting(seenKinds).sorted()
    guard missing.isEmpty else {
      throw QixiRealDeviceEvidenceValidationError.missingArtifactKinds(missing)
    }
  }

  private struct PortableArtifactPath {
    var normalized: String
    var components: [String]
  }

  private static func portableArtifactPath(_ rawPath: String) throws -> PortableArtifactPath {
    if rawPath.hasPrefix("~") {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact path must be relative to the evidence file, not a home-relative path."
      )
    }
    if rawPath.hasPrefix("/") {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact path must be relative to the evidence file, not an absolute path."
      )
    }
    if rawPath.contains("\\") {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact path must use portable POSIX separators."
      )
    }
    let components = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." }) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Artifact path must name a relative artifact file.")
    }
    guard !components.contains("..") else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact path must not traverse outside the evidence directory."
      )
    }
    return PortableArtifactPath(normalized: components.joined(separator: "/"), components: components)
  }

  private static func rejectReservedArtifactPath(
    _ portablePath: PortableArtifactPath,
    evidenceURL: URL?
  ) throws {
    if let filename = portablePath.components.last,
       reservedArtifactFilenames.contains(filename) {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact path must not use reserved real-device evidence filenames: \(portablePath.normalized)"
      )
    }
    guard let evidenceURL else { return }
    let artifactURL = resolveArtifactURL(
      baseURL: evidenceURL.deletingLastPathComponent(),
      portablePath: portablePath
    )
    if artifactURL.standardizedFileURL.path == evidenceURL.standardizedFileURL.path {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact path must not overwrite the real-device evidence file: \(portablePath.normalized)"
      )
    }
  }

  private static func resolveArtifactURL(baseURL: URL, portablePath: PortableArtifactPath) -> URL {
    var url = baseURL
    for component in portablePath.components {
      url.appendPathComponent(component, isDirectory: false)
    }
    return url
  }

  private static func rejectSymbolicLinkComponents(in url: URL, label: String) throws {
    let components = url.standardizedFileURL.pathComponents
    guard !components.isEmpty else { return }
    var currentPath = components[0]
    for component in components.dropFirst() {
      currentPath = (currentPath as NSString).appendingPathComponent(component)
      let currentURL = URL(fileURLWithPath: currentPath)
      let values = try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true,
         !isAllowedPlatformSymlinkAlias(currentURL) {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "\(label) must not contain symbolic links: \(currentURL.path)"
        )
      }
    }
  }

  private static func isAllowedPlatformSymlinkAlias(_ url: URL) -> Bool {
    #if os(macOS) || os(iOS)
    let allowedAliases = [
      "/var": "private/var",
      "/tmp": "private/tmp",
      "/etc": "private/etc"
    ]
    guard let expectedTarget = allowedAliases[url.path] else { return false }
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
      return false
    }
    return target == expectedTarget || target == "/\(expectedTarget)"
    #else
    return false
    #endif
  }

  static func fingerprintedArtifact(kind: String, path rawPath: String, evidenceURL: URL) throws -> QixiRealDeviceEvidence.Artifact {
    let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let portablePath = try portableArtifactPath(trimmedPath)
    try rejectReservedArtifactPath(portablePath, evidenceURL: evidenceURL)
    let artifactURL = try regularArtifactFileURL(
      baseURL: evidenceURL.deletingLastPathComponent(),
      portablePath: portablePath
    )
    let byteCount = try QixiNativeModelIntegrity.byteCount(of: artifactURL)
    try validateArtifactByteBudget(kind: trimmedKind, artifactURL: artifactURL, actualByteCount: byteCount)
    let digest = try QixiNativeModelIntegrity.sha256HexDigest(of: artifactURL)
    return QixiRealDeviceEvidence.Artifact(
      kind: trimmedKind,
      path: trimmedPath,
      byteCount: byteCount,
      sha256HexDigest: digest
    )
  }

  static func writeDeviceLogArtifact(
    for evidence: QixiRealDeviceEvidence,
    path rawPath: String,
    evidenceURL: URL
  ) throws -> QixiRealDeviceEvidence.Artifact {
    let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let portablePath = try portableArtifactPath(trimmedPath)
    try rejectReservedArtifactPath(portablePath, evidenceURL: evidenceURL)
    let artifactURL = resolveArtifactURL(
      baseURL: evidenceURL.deletingLastPathComponent(),
      portablePath: portablePath
    )
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: artifactURL.deletingLastPathComponent(),
      label: "Real-device device-log artifact directory"
    )
    try rejectSymbolicLinkComponents(in: artifactURL, label: "Real-device device-log artifact path")
    let values = try? artifactURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact path must not be a symbolic link: \(artifactURL.path)"
      )
    }
    if values?.isDirectory == true || (FileManager.default.fileExists(atPath: artifactURL.path) && values?.isRegularFile != true) {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact path must be a regular file: \(artifactURL.path)"
      )
    }
    let data = try deviceLogArtifactData(for: evidence)
    guard data.count <= maxDeviceLogArtifactBytes else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Generated device-log artifact exceeds bounded artifact size of \(maxDeviceLogArtifactBytes) bytes: \(artifactURL.path)"
      )
    }
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: artifactURL,
      label: "Real-device device-log artifact path"
    )
    return try fingerprintedArtifact(kind: "device-log", path: trimmedPath, evidenceURL: evidenceURL)
  }

  static func deviceLogArtifactData(for evidence: QixiRealDeviceEvidence) throws -> Data {
    var analysis: [String: Any] = [
      "engineId": evidence.analysis.engineId.rawValue,
      "realModel": evidence.analysis.realModel,
      "visits": evidence.analysis.visits,
      "candidateCount": evidence.analysis.candidateCount,
      "ownershipSource": evidence.analysis.ownershipSource,
      "positionIdentity": [
        "currentPositionKey": evidence.analysis.positionIdentity.currentPositionKey,
        "sameVisibleStones": evidence.analysis.positionIdentity.sameVisibleStones,
        "sameVisibleHistoryAKey": evidence.analysis.positionIdentity.sameVisibleHistoryAKey,
        "sameVisibleHistoryBKey": evidence.analysis.positionIdentity.sameVisibleHistoryBKey,
        "sameVisibleHistoryKeysDistinct": evidence.analysis.positionIdentity.sameVisibleHistoryKeysDistinct
      ]
    ]
    if let nativeEngine = evidence.analysis.nativeEngine {
      analysis["nativeEngine"] = [
        "modelDigestVerified": nativeEngine.modelDigestVerified,
        "engineId": nativeEngine.engineId.rawValue,
        "modelResourceName": nativeEngine.modelResourceName,
        "modelByteCount": try jsonInt(nativeEngine.modelByteCount, path: "analysis.nativeEngine.modelByteCount"),
        "modelSHA256HexDigest": nativeEngine.modelSHA256HexDigest,
        "coreMLPackages": try nativeEngine.coreMLPackages.map { package in
          [
            "resourceName": package.resourceName,
            "variantID": package.variantID,
            "fileCount": package.fileCount,
            "totalByteCount": try jsonInt(
              package.totalByteCount,
              path: "analysis.nativeEngine.coreMLPackages.totalByteCount"
            ),
            "sha256TreeDigest": package.sha256TreeDigest
          ] as [String: Any]
        },
        "tombstoneExported": nativeEngine.tombstoneExported,
        "tombstoneFilename": nativeEngine.tombstoneFilename,
        "tombstoneExportedAt": iso8601String(nativeEngine.tombstoneExportedAt),
        "tombstoneRestored": nativeEngine.tombstoneRestored,
        "tombstoneRestoredAt": iso8601String(nativeEngine.tombstoneRestoredAt)
      ]
    }
    var payload: [String: Any] = [
      "schemaVersion": deviceLogArtifactSchemaVersion,
      "kind": "qixi-real-device-log",
      "runId": evidence.runId,
      "recordedAt": iso8601String(evidence.recordedAt),
      "device": [
        "idiom": evidence.device.idiom,
        "model": evidence.device.model,
        "osVersion": evidence.device.osVersion,
        "simulator": evidence.device.simulator
      ],
      "app": [
        "bundleIdentifier": evidence.app.bundleIdentifier,
        "version": evidence.app.version,
        "build": evidence.app.build,
        "analysisRuntime": evidence.app.analysisRuntime,
        "executableSHA256HexDigest": evidence.app.executableSHA256HexDigest
      ],
      "analysis": analysis,
      "lifecycle": [
        "backgroundedSeconds": evidence.lifecycle.backgroundedSeconds,
        "autosaveWritten": evidence.lifecycle.autosaveWritten,
        "tombstoneWritten": evidence.lifecycle.tombstoneWritten,
        "restoredLatestState": evidence.lifecycle.restoredLatestState
      ],
      "features": [
        "cameraRecognitionTested": evidence.features.cameraRecognitionTested,
        "iCloudSyncTested": evidence.features.iCloudSyncTested,
        "modelImportTested": evidence.features.modelImportTested
      ]
    ]
    if let backend = evidence.backend {
      payload["backend"] = [
        "url": backend.url,
        "status": [
          "engine": backend.status.engine,
          "engineId": backend.status.engineId,
          "state": backend.status.state,
          "running": backend.status.running,
          "paused": backend.status.paused
        ]
      ]
    }
    guard JSONSerialization.isValidJSONObject(payload) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Generated device-log artifact is not valid JSON.")
    }
    var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    data.append(0x0A)
    return data
  }

  private static func jsonInt(_ value: UInt64, path: String) throws -> Int {
    guard value <= UInt64(Int.max) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact \(path) exceeds JSON integer range."
      )
    }
    return Int(value)
  }

  private static func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  private static func regularArtifactFileURL(
    baseURL: URL,
    portablePath: PortableArtifactPath
  ) throws -> URL {
    var url = baseURL
    for component in portablePath.components {
      url.appendPathComponent(component, isDirectory: false)
      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Artifact path must not contain symbolic links: \(url.path)"
        )
      }
    }

    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    guard values?.isSymbolicLink != true else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact path must not contain symbolic links: \(url.path)"
      )
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Artifact file is missing: \(url.path)")
    }
    guard values?.isRegularFile == true, values?.isDirectory != true else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact file must be a regular file: \(url.path)"
      )
    }
    return url
  }

  private static func maxArtifactBytes(for kind: String) -> UInt64 {
    switch kind {
    case "screenshot":
      return UInt64(maxScreenshotArtifactBytes)
    case "performance":
      return UInt64(maxPerformanceArtifactBytes)
    case "device-log":
      return UInt64(maxDeviceLogArtifactBytes)
    default:
      return 0
    }
  }

  private static func validateArtifactByteBudget(
    kind: String,
    artifactURL: URL,
    actualByteCount: UInt64
  ) throws {
    let maxBytes = maxArtifactBytes(for: kind)
    guard maxBytes > 0 else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact("Artifact kind is unsupported: \(kind)")
    }
    guard actualByteCount <= maxBytes else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact \(kind) exceeds bounded artifact size of \(maxBytes) bytes before fingerprinting: \(artifactURL.path)"
      )
    }
  }

  private static func validateArtifactFingerprint(
    _ artifact: QixiRealDeviceEvidence.Artifact,
    kind: String,
    artifactURL: URL,
    actualByteCount: UInt64
  ) throws -> ArtifactFileFingerprint {
    guard artifact.byteCount == actualByteCount else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact \(kind) byteCount must match file byte count: \(artifactURL.path)"
      )
    }
    guard Self.isLowercaseSHA256HexDigest(artifact.sha256HexDigest) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact \(kind) sha256HexDigest must be a lowercase SHA-256 hex digest."
      )
    }
    let actualDigest = try QixiNativeModelIntegrity.sha256HexDigest(of: artifactURL)
    guard artifact.sha256HexDigest == actualDigest else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact \(kind) sha256HexDigest must match file SHA-256: \(artifactURL.path)"
      )
    }
    return ArtifactFileFingerprint(byteCount: actualByteCount, sha256HexDigest: actualDigest)
  }

  private struct ArtifactFileFingerprint: Equatable {
    var byteCount: UInt64
    var sha256HexDigest: String
  }

  private struct StrictArtifactJSONObject {
    var payload: [String: Any]
    var fingerprint: ArtifactFileFingerprint
  }

  private static func validateArtifactFingerprintStableAfterContent(
    _ artifact: QixiRealDeviceEvidence.Artifact,
    kind: String,
    artifactURL: URL,
    expectedFingerprint: ArtifactFileFingerprint
  ) throws {
    let actualByteCount = try QixiNativeModelIntegrity.byteCount(of: artifactURL)
    try validateArtifactByteBudget(kind: kind, artifactURL: artifactURL, actualByteCount: actualByteCount)
    let actualFingerprint = try validateArtifactFingerprint(
      artifact,
      kind: kind,
      artifactURL: artifactURL,
      actualByteCount: actualByteCount
    )
    guard actualFingerprint == expectedFingerprint else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Artifact \(kind) changed while validating content: \(artifactURL.path)"
      )
    }
  }

  private static func validateArtifactContent(
    kind: String,
    artifactURL: URL,
    evidence: QixiRealDeviceEvidence
  ) throws -> ArtifactFileFingerprint? {
    switch kind {
    case "screenshot":
      let dimensions = try pngDimensions(for: artifactURL)
      guard dimensions.width > dimensions.height else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Screenshot artifact must be landscape for \(evidence.device.idiom): \(dimensions.width)x\(dimensions.height) \(artifactURL.path)"
        )
      }
      let minimum: (width: Int, height: Int)
      if evidence.device.idiom == "iPad" {
        minimum = iPadMinimumScreenshotSize
      } else if evidence.device.idiom == "iPhone" {
        minimum = iPhoneMinimumScreenshotSize
      } else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Device idiom has no screenshot size budget: \(evidence.device.idiom)"
        )
      }
      guard dimensions.width >= minimum.width && dimensions.height >= minimum.height else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Screenshot artifact is too small for \(evidence.device.idiom): \(dimensions.width)x\(dimensions.height), expected at least \(minimum.width)x\(minimum.height)"
        )
      }
      guard dimensions.height > 0 && dimensions.width <= maxScreenshotPixels / dimensions.height else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Screenshot artifact is too large for bounded visual inspection: \(dimensions.width)x\(dimensions.height), maximum \(maxScreenshotPixels) pixels \(artifactURL.path)"
        )
      }
      try validateScreenshotVisualContent(artifactURL: artifactURL, dimensions: dimensions)
      return nil
    case "performance":
      let json = try strictArtifactJSONObject(
        artifactName: "Performance artifact",
        label: "Qixi real-device performance artifact",
        artifactURL: artifactURL,
        maxBytes: maxPerformanceArtifactBytes
      )
      try validatePerformanceArtifact(json.payload, artifactURL: artifactURL, evidence: evidence)
      return json.fingerprint
    case "device-log":
      let json = try strictArtifactJSONObject(
        artifactName: "Device-log artifact",
        label: "Qixi real-device device-log artifact",
        artifactURL: artifactURL,
        maxBytes: maxDeviceLogArtifactBytes
      )
      try validateDeviceLogArtifact(json.payload, artifactURL: artifactURL, evidence: evidence)
      return json.fingerprint
    default:
      return nil
    }
  }

  private static func strictArtifactJSONObject(
    artifactName: String,
    label: String,
    artifactURL: URL,
    maxBytes: Int
  ) throws -> StrictArtifactJSONObject {
    do {
      let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
        from: artifactURL,
        label: label,
        maxBytes: maxBytes
      )
      guard let payload = try JSONSerialization.jsonObject(with: objectData) as? [String: Any] else {
        throw QixiStrictJSONError.malformed(label: label, message: "must decode to a JSON object")
      }
      return StrictArtifactJSONObject(
        payload: payload,
        fingerprint: ArtifactFileFingerprint(
          byteCount: UInt64(objectData.count),
          sha256HexDigest: sha256HexDigest(of: objectData)
        )
      )
    } catch {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "\(artifactName) must be standards-compliant JSON object without duplicate keys, non-standard constants, or oversized content: \(artifactURL.path) (\(error))"
      )
    }
  }

  private static func sha256HexDigest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func validatePerformanceArtifact(
    _ payload: [String: Any],
    artifactURL: URL,
    evidence: QixiRealDeviceEvidence
  ) throws {
    try validateArtifactSchemaVersion(
      payload,
      artifactURL: artifactURL,
      kind: "Performance artifact",
      expected: performanceArtifactSchemaVersion
    )
    guard payload["kind"] as? String == performanceArtifactKind else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Performance artifact kind must be \(performanceArtifactKind): \(artifactURL.path)"
      )
    }
    guard let source = payload["source"] as? String,
          validPerformanceArtifactSources.contains(source) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Performance artifact source must be instruments, xctrace, or metricKit: \(artifactURL.path)"
      )
    }
    try compareArtifactRecordedAt(
      payload,
      artifactURL: artifactURL,
      kind: "Performance artifact",
      expected: evidence.recordedAt,
      allowStagedBeforeEvidence: true
    )
    try compareArtifactRunId(
      payload,
      artifactURL: artifactURL,
      kind: "Performance artifact",
      expected: evidence.runId
    )
    guard let artifactMeasurements = payload["measurements"] as? [String: Any] else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Performance artifact measurements must match real-device evidence measurements: missing measurements in \(artifactURL.path)"
      )
    }
    try comparePerformanceMeasurement(
      artifactMeasurements,
      artifactURL: artifactURL,
      section: "launch",
      field: "coldLaunchMs",
      expected: Double(evidence.measurements.launch.coldLaunchMs)
    )
    try comparePerformanceMeasurement(
      artifactMeasurements,
      artifactURL: artifactURL,
      section: "launch",
      field: "visualReadyMs",
      expected: Double(evidence.measurements.launch.visualReadyMs)
    )
    try comparePerformanceMeasurement(
      artifactMeasurements,
      artifactURL: artifactURL,
      section: "memory",
      field: "peakRSSMB",
      expected: evidence.measurements.memory.peakRSSMB
    )
    try comparePerformanceMeasurement(
      artifactMeasurements,
      artifactURL: artifactURL,
      section: "memory",
      field: "postAnalysisRSSMB",
      expected: evidence.measurements.memory.postAnalysisRSSMB
    )
    try comparePerformanceMeasurement(
      artifactMeasurements,
      artifactURL: artifactURL,
      section: "framePacing",
      field: "targetRefreshHz",
      expected: Double(evidence.measurements.framePacing.targetRefreshHz)
    )
    try comparePerformanceMeasurement(
      artifactMeasurements,
      artifactURL: artifactURL,
      section: "framePacing",
      field: "observedRefreshHz",
      expected: evidence.measurements.framePacing.observedRefreshHz
    )
    try comparePerformanceMeasurement(
      artifactMeasurements,
      artifactURL: artifactURL,
      section: "framePacing",
      field: "droppedFramePercent",
      expected: evidence.measurements.framePacing.droppedFramePercent
    )
  }

  private static func compareArtifactRecordedAt(
    _ payload: [String: Any],
    artifactURL: URL,
    kind: String,
    expected: Date,
    allowStagedBeforeEvidence: Bool = false
  ) throws {
    guard let rawRecordedAt = payload["recordedAt"] as? String,
          let recordedAt = parseISO8601Date(rawRecordedAt) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "\(kind) recordedAt must be an ISO-8601 string matching real-device evidence recordedAt: \(artifactURL.path)"
      )
    }
    if allowStagedBeforeEvidence {
      guard recordedAt.timeIntervalSince(expected) <= artifactRecordedAtTolerance else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "\(kind) recordedAt must not be newer than real-device evidence recordedAt: \(artifactURL.path)"
        )
      }
      guard expected.timeIntervalSince(recordedAt) <= maximumStagedArtifactAge else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "\(kind) recordedAt is too old for staged real-device evidence: \(artifactURL.path)"
        )
      }
      return
    }
    guard abs(recordedAt.timeIntervalSince(expected)) <= artifactRecordedAtTolerance else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "\(kind) recordedAt must match real-device evidence recordedAt: \(artifactURL.path)"
      )
    }
  }

  private static func compareArtifactRunId(
    _ payload: [String: Any],
    artifactURL: URL,
    kind: String,
    expected: String
  ) throws {
    guard payload["runId"] as? String == expected else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "\(kind) runId must match real-device evidence runId: \(artifactURL.path)"
      )
    }
  }

  private static func validateArtifactSchemaVersion(
    _ payload: [String: Any],
    artifactURL: URL,
    kind: String,
    expected: Int
  ) throws {
    guard let rawValue = payload["schemaVersion"] else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "\(kind) schemaVersion must be \(expected): \(artifactURL.path)"
      )
    }
    let matchesExpected: Bool
    if let actual = rawValue as? NSNumber {
      let isBoolean = CFGetTypeID(actual) == CFBooleanGetTypeID()
      matchesExpected = !isBoolean &&
        actual.intValue == expected &&
        abs(actual.doubleValue - Double(expected)) <= 1e-9
    } else if let actual = rawValue as? Int {
      matchesExpected = actual == expected
    } else {
      matchesExpected = false
    }
    guard matchesExpected else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "\(kind) schemaVersion must be \(expected): \(artifactURL.path)"
      )
    }
  }

  private static func comparePerformanceMeasurement(
    _ artifactMeasurements: [String: Any],
    artifactURL: URL,
    section: String,
    field: String,
    expected: Double
  ) throws {
    guard let sectionPayload = artifactMeasurements[section] as? [String: Any] else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Performance artifact measurements.\(section) must match real-device evidence measurements: \(artifactURL.path)"
      )
    }
    let path = "measurements.\(section).\(field)"
    let value = sectionPayload[field]
    guard !(value is Bool), let actual = value as? NSNumber else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Performance artifact \(path) must be numeric: \(artifactURL.path)"
      )
    }
    guard abs(actual.doubleValue - expected) <= 1e-9 else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Performance artifact \(path) must match real-device evidence measurements: \(artifactURL.path)"
      )
    }
  }

  private static func validateDeviceLogArtifact(
    _ payload: [String: Any],
    artifactURL: URL,
    evidence: QixiRealDeviceEvidence
  ) throws {
    try validateArtifactSchemaVersion(
      payload,
      artifactURL: artifactURL,
      kind: "Device-log artifact",
      expected: deviceLogArtifactSchemaVersion
    )
    guard payload["kind"] as? String == "qixi-real-device-log" else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact kind must be qixi-real-device-log: \(artifactURL.path)"
      )
    }
    try compareArtifactRecordedAt(
      payload,
      artifactURL: artifactURL,
      kind: "Device-log artifact",
      expected: evidence.recordedAt
    )
    try compareArtifactRunId(
      payload,
      artifactURL: artifactURL,
      kind: "Device-log artifact",
      expected: evidence.runId
    )
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["device", "idiom"], expected: evidence.device.idiom)
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["device", "model"], expected: evidence.device.model)
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["device", "osVersion"], expected: evidence.device.osVersion)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["device", "simulator"], expected: evidence.device.simulator)
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["app", "bundleIdentifier"], expected: evidence.app.bundleIdentifier)
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["app", "version"], expected: evidence.app.version)
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["app", "build"], expected: evidence.app.build)
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["app", "analysisRuntime"], expected: evidence.app.analysisRuntime)
    try compareDeviceLogString(
      payload,
      artifactURL: artifactURL,
      path: ["app", "executableSHA256HexDigest"],
      expected: evidence.app.executableSHA256HexDigest
    )
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["analysis", "engineId"], expected: evidence.analysis.engineId.rawValue)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["analysis", "realModel"], expected: evidence.analysis.realModel)
    try compareDeviceLogInt(payload, artifactURL: artifactURL, path: ["analysis", "visits"], expected: evidence.analysis.visits)
    try compareDeviceLogInt(payload, artifactURL: artifactURL, path: ["analysis", "candidateCount"], expected: evidence.analysis.candidateCount)
    try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["analysis", "ownershipSource"], expected: evidence.analysis.ownershipSource)
    try compareDeviceLogPositionIdentity(payload, artifactURL: artifactURL, expected: evidence.analysis.positionIdentity)
    try compareDeviceLogInt(payload, artifactURL: artifactURL, path: ["lifecycle", "backgroundedSeconds"], expected: evidence.lifecycle.backgroundedSeconds)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["lifecycle", "autosaveWritten"], expected: evidence.lifecycle.autosaveWritten)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["lifecycle", "tombstoneWritten"], expected: evidence.lifecycle.tombstoneWritten)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["lifecycle", "restoredLatestState"], expected: evidence.lifecycle.restoredLatestState)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["features", "cameraRecognitionTested"], expected: evidence.features.cameraRecognitionTested)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["features", "iCloudSyncTested"], expected: evidence.features.iCloudSyncTested)
    try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["features", "modelImportTested"], expected: evidence.features.modelImportTested)

    if evidence.app.analysisRuntime == "httpBridge" {
      guard let backend = evidence.backend else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Device-log artifact cannot prove missing backend evidence: \(artifactURL.path)"
        )
      }
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["backend", "url"], expected: backend.url)
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["backend", "status", "engine"], expected: backend.status.engine)
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["backend", "status", "engineId"], expected: backend.status.engineId)
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["backend", "status", "state"], expected: backend.status.state)
      try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["backend", "status", "running"], expected: backend.status.running)
      try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["backend", "status", "paused"], expected: backend.status.paused)
    } else {
      guard let nativeEngine = evidence.analysis.nativeEngine else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Device-log artifact cannot prove missing native engine evidence: \(artifactURL.path)"
        )
      }
      try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "modelDigestVerified"], expected: nativeEngine.modelDigestVerified)
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "engineId"], expected: nativeEngine.engineId.rawValue)
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "modelResourceName"], expected: nativeEngine.modelResourceName)
      try compareDeviceLogUInt64(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "modelByteCount"], expected: nativeEngine.modelByteCount)
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "modelSHA256HexDigest"], expected: nativeEngine.modelSHA256HexDigest)
      try compareDeviceLogCoreMLPackages(payload, artifactURL: artifactURL, nativeEngine: nativeEngine)
      try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "tombstoneExported"], expected: nativeEngine.tombstoneExported)
      try compareDeviceLogString(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "tombstoneFilename"], expected: nativeEngine.tombstoneFilename)
      try compareDeviceLogDate(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "tombstoneExportedAt"], expected: nativeEngine.tombstoneExportedAt)
      try compareDeviceLogBool(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "tombstoneRestored"], expected: nativeEngine.tombstoneRestored)
      try compareDeviceLogDate(payload, artifactURL: artifactURL, path: ["analysis", "nativeEngine", "tombstoneRestoredAt"], expected: nativeEngine.tombstoneRestoredAt)
      if payload.keys.contains("backend") {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Device-log artifact for nativeInProcess evidence must omit backend: \(artifactURL.path)"
        )
      }
    }
  }

  private static func deviceLogRawValue(_ payload: [String: Any], path: [String], artifactURL: URL) throws -> Any {
    var current: Any = payload
    for component in path {
      guard let dictionary = current as? [String: Any],
            let next = dictionary[component] else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Device-log artifact \(path.joined(separator: ".")) must match real-device evidence: \(artifactURL.path)"
        )
      }
      current = next
    }
    return current
  }

  private static func compareDeviceLogString(
    _ payload: [String: Any],
    artifactURL: URL,
    path: [String],
    expected: String
  ) throws {
    guard let actual = try deviceLogRawValue(payload, path: path, artifactURL: artifactURL) as? String,
          actual == expected else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact \(path.joined(separator: ".")) must match real-device evidence: \(artifactURL.path)"
      )
    }
  }

  private static func compareDeviceLogBool(
    _ payload: [String: Any],
    artifactURL: URL,
    path: [String],
    expected: Bool
  ) throws {
    guard let actual = try deviceLogRawValue(payload, path: path, artifactURL: artifactURL) as? Bool,
          actual == expected else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact \(path.joined(separator: ".")) must match real-device evidence: \(artifactURL.path)"
      )
    }
  }

  private static func compareDeviceLogInt(
    _ payload: [String: Any],
    artifactURL: URL,
    path: [String],
    expected: Int
  ) throws {
    let rawValue = try deviceLogRawValue(payload, path: path, artifactURL: artifactURL)
    guard !(rawValue is Bool),
          let actual = rawValue as? NSNumber,
          actual.intValue == expected,
          abs(actual.doubleValue - Double(expected)) <= 1e-9 else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact \(path.joined(separator: ".")) must match real-device evidence: \(artifactURL.path)"
      )
    }
  }

  private static func compareDeviceLogUInt64(
    _ payload: [String: Any],
    artifactURL: URL,
    path: [String],
    expected: UInt64
  ) throws {
    let rawValue = try deviceLogRawValue(payload, path: path, artifactURL: artifactURL)
    guard !(rawValue is Bool),
          let actual = rawValue as? NSNumber,
          actual.uint64Value == expected,
          actual.doubleValue >= 0,
          abs(actual.doubleValue - Double(expected)) <= 1e-9 else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact \(path.joined(separator: ".")) must match real-device evidence: \(artifactURL.path)"
      )
    }
  }

  private static func compareDeviceLogCoreMLPackages(
    _ payload: [String: Any],
    artifactURL: URL,
    nativeEngine: QixiRealDeviceEvidence.NativeEngine
  ) throws {
    let path = ["analysis", "nativeEngine", "coreMLPackages"]
    guard let packages = try deviceLogRawValue(payload, path: path, artifactURL: artifactURL) as? [[String: Any]],
          packages.count == nativeEngine.coreMLPackages.count else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact \(path.joined(separator: ".")) must match real-device evidence: \(artifactURL.path)"
      )
    }
    for (index, expected) in nativeEngine.coreMLPackages.enumerated() {
      let package = packages[index]
      guard package["resourceName"] as? String == expected.resourceName,
            package["variantID"] as? String == expected.variantID,
            !(package["fileCount"] is Bool),
            let fileCount = package["fileCount"] as? NSNumber,
            fileCount.intValue == expected.fileCount,
            !(package["totalByteCount"] is Bool),
            let totalByteCount = package["totalByteCount"] as? NSNumber,
            totalByteCount.uint64Value == expected.totalByteCount,
            totalByteCount.doubleValue >= 0,
            package["sha256TreeDigest"] as? String == expected.sha256TreeDigest else {
        throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
          "Device-log artifact \(path.joined(separator: ".")).\(index) must match real-device evidence: \(artifactURL.path)"
        )
      }
    }
  }

  private static func compareDeviceLogPositionIdentity(
    _ payload: [String: Any],
    artifactURL: URL,
    expected: QixiRealDeviceEvidence.PositionIdentity
  ) throws {
    try compareDeviceLogString(
      payload,
      artifactURL: artifactURL,
      path: ["analysis", "positionIdentity", "currentPositionKey"],
      expected: expected.currentPositionKey
    )
    try compareDeviceLogBool(
      payload,
      artifactURL: artifactURL,
      path: ["analysis", "positionIdentity", "sameVisibleStones"],
      expected: expected.sameVisibleStones
    )
    try compareDeviceLogString(
      payload,
      artifactURL: artifactURL,
      path: ["analysis", "positionIdentity", "sameVisibleHistoryAKey"],
      expected: expected.sameVisibleHistoryAKey
    )
    try compareDeviceLogString(
      payload,
      artifactURL: artifactURL,
      path: ["analysis", "positionIdentity", "sameVisibleHistoryBKey"],
      expected: expected.sameVisibleHistoryBKey
    )
    try compareDeviceLogBool(
      payload,
      artifactURL: artifactURL,
      path: ["analysis", "positionIdentity", "sameVisibleHistoryKeysDistinct"],
      expected: expected.sameVisibleHistoryKeysDistinct
    )
  }

  private static func compareDeviceLogDate(
    _ payload: [String: Any],
    artifactURL: URL,
    path: [String],
    expected: Date
  ) throws {
    guard let rawValue = try deviceLogRawValue(payload, path: path, artifactURL: artifactURL) as? String,
          let actual = parseISO8601Date(rawValue),
          abs(actual.timeIntervalSince(expected)) <= artifactRecordedAtTolerance else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Device-log artifact \(path.joined(separator: ".")) must match real-device evidence: \(artifactURL.path)"
      )
    }
  }

  static func parseISO8601Date(_ rawValue: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: rawValue) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: rawValue)
  }

  private static func pngDimensions(for artifactURL: URL) throws -> (width: Int, height: Int) {
    let data: Data
    do {
      let handle = try FileHandle(forReadingFrom: artifactURL)
      defer { try? handle.close() }
      data = handle.readData(ofLength: pngHeaderByteCount)
    } catch {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact must be a PNG file: \(artifactURL.path)"
      )
    }
    guard data.count >= pngHeaderByteCount,
          data.prefix(pngSignature.count) == pngSignature else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact must be a PNG file: \(artifactURL.path)"
      )
    }
    let ihdrLength = readBigEndianUInt32(data, offset: 8)
    let ihdrKind = Data(data[12..<16])
    guard ihdrLength == 13 && ihdrKind == Data("IHDR".utf8) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact must have a valid PNG IHDR: \(artifactURL.path)"
      )
    }
    let width = readBigEndianUInt32(data, offset: 16)
    let height = readBigEndianUInt32(data, offset: 20)
    guard width > 0 && height > 0 else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact has invalid PNG dimensions: \(artifactURL.path)"
      )
    }
    return (width, height)
  }

  private static func validateScreenshotVisualContent(
    artifactURL: URL,
    dimensions: (width: Int, height: Int)
  ) throws {
    guard let source = CGImageSourceCreateWithURL(artifactURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact must be a decodable PNG image: \(artifactURL.path)"
      )
    }
    guard image.width == dimensions.width && image.height == dimensions.height else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact decoded dimensions must match PNG IHDR: \(artifactURL.path)"
      )
    }

    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    let pixelCount = width * height
    var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let stats = buffer.withUnsafeMutableBytes { rawBuffer -> (variance: Double, darkPixels: Int)? in
      guard let baseAddress = rawBuffer.baseAddress,
            let context = CGContext(
              data: baseAddress,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: bitmapInfo
            ) else {
        return nil
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

      var darkPixels = 0
      var redSum = 0.0
      var greenSum = 0.0
      var blueSum = 0.0
      var redSquareSum = 0.0
      var greenSquareSum = 0.0
      var blueSquareSum = 0.0
      for offset in stride(from: 0, to: rawBuffer.count, by: bytesPerPixel) {
        let red = Double(rawBuffer[offset])
        let green = Double(rawBuffer[offset + 1])
        let blue = Double(rawBuffer[offset + 2])
        redSum += red
        greenSum += green
        blueSum += blue
        redSquareSum += red * red
        greenSquareSum += green * green
        blueSquareSum += blue * blue
        if max(red, max(green, blue)) < 72 {
          darkPixels += 1
        }
      }
      let count = Double(pixelCount)
      func standardDeviation(sum: Double, squareSum: Double) -> Double {
        let mean = sum / count
        return sqrt(max(0, squareSum / count - mean * mean))
      }
      return (
        standardDeviation(sum: redSum, squareSum: redSquareSum) +
          standardDeviation(sum: greenSum, squareSum: greenSquareSum) +
          standardDeviation(sum: blueSum, squareSum: blueSquareSum),
        darkPixels
      )
    }
    guard let stats else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact could not be inspected: \(artifactURL.path)"
      )
    }
    guard stats.variance >= minimumScreenshotVisualVariance else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact looks blank or nearly flat: \(artifactURL.path)"
      )
    }
    let requiredDarkPixels = max(
      minimumScreenshotDarkPixels,
      Int(Double(pixelCount) * minimumScreenshotDarkPixelRatio)
    )
    guard stats.darkPixels >= requiredDarkPixels else {
      throw QixiRealDeviceEvidenceValidationError.invalidArtifact(
        "Screenshot artifact lacks visible board/grid detail: \(artifactURL.path)"
      )
    }
  }

  private static func readBigEndianUInt32(_ data: Data, offset: Int) -> Int {
    var value: UInt32 = 0
    for byteOffset in 0..<4 {
      value = (value << 8) | UInt32(data[offset + byteOffset])
    }
    return Int(value)
  }
}
