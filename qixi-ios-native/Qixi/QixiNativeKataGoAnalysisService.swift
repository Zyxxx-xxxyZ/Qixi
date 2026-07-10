import Foundation

enum QixiNativeKataGoServiceError: Error, LocalizedError {
  case libraryNotLinked
  case modelMissing(String)
  case invalidRequest(String)
  case invalidBridgeResponse(String)
  case insufficientDeviceMemory(NativeKataGoMemoryBudgetReport)

  var errorDescription: String? {
    switch self {
    case .libraryNotLinked:
      #if QIXI_NATIVE_RELEASE
      return "Native KataGo link failed in this NativeRelease build."
      #else
      return "Native KataGo is not linked into this build."
      #endif
    case .modelMissing(let resourceName):
      return "Native KataGo model is not installed: \(resourceName)"
    case .invalidRequest(let message):
      return message
    case .invalidBridgeResponse(let message):
      return message
    case .insufficientDeviceMemory(let report):
      return "Native KataGo model \(report.engine.rawValue) requires at least \(report.minimumMemoryMB) MB after a \(report.reservedSystemMemoryMB) MB system reserve; this device reports \(report.physicalMemoryMB) MB."
    }
  }
}

protocol NativeKataGoBridgeProtocol: AnyObject {
  var isLinked: Bool { get }
  func configureModel(
    _ engineID: String,
    resourceName: String,
    modelPath: String,
    coreMLPackagePaths: [String],
    minimumMemoryMB: Int32,
    recommendedMemoryMB: Int32,
    maximumMemoryMB: Int32
  ) throws
  func loadEngine(_ engineID: String) throws
  func analyzeRequestJSON(_ requestJSON: String) throws -> String
  func exportTombstone(to url: URL) throws
  func restoreTombstone(from url: URL) throws
  func submitCoreRequestJSON(_ requestJSON: String) throws -> String
  func latestCoreSnapshotJSON() throws -> String
  func legalMoveMaskJSON() throws -> String
  func exportCoreState(to url: URL) throws
  func importCoreState(from url: URL) throws
}

extension QixiNativeKataGoBridge: NativeKataGoBridgeProtocol {
  func exportTombstone(to url: URL) throws {
    try exportTombstone(toFile: url.path)
  }

  func restoreTombstone(from url: URL) throws {
    try restoreTombstone(fromFile: url.path)
  }

  func exportCoreState(to url: URL) throws {
    try exportCoreState(toFile: url.path)
  }

  func importCoreState(from url: URL) throws {
    try importCoreState(fromFile: url.path)
  }
}

actor NativeKataGoAnalysisService: QixiAnalysisService, QixiEngineTombstoneService, QixiCoreBackendService {
  nonisolated var runtime: QixiAnalysisRuntime { .nativeInProcess }
  private static let nativeErrorDomain = "QixiNativeKataGo"
  private static let libraryNotLinkedErrorCode = 1
  private static let invalidRequestErrorCode = 2

  private let bridge: NativeKataGoBridgeProtocol
  private let modelStore: QixiNativeModelStore
  private let memoryPolicy: QixiNativeDeviceMemoryPolicy
  private var currentEngine: AnalysisEngine = .none
  private let coreJSONEncoder = JSONEncoder()
  private let coreJSONDecoder = JSONDecoder()

  init(
    bridge: NativeKataGoBridgeProtocol = QixiNativeKataGoBridge(),
    modelStore: QixiNativeModelStore = QixiNativeModelStore(),
    memoryPolicy: QixiNativeDeviceMemoryPolicy = QixiNativeDeviceMemoryPolicy()
  ) {
    self.bridge = bridge
    self.modelStore = modelStore
    self.memoryPolicy = memoryPolicy
  }

  func setEngine(_ engine: AnalysisEngine) async throws -> BackendStatusResponse {
    do {
      if currentEngine == engine {
        return BackendStatusResponse(
          engine: engine.rawValue,
          engineId: engine.rawValue,
          state: engine == .none ? "no engine loaded" : "native engine already loaded",
          running: engine != .none,
          paused: false
        )
      }
      if engine != .none, let spec = QixiNativeModelRegistry.spec(for: engine) {
        guard bridge.isLinked else {
          throw QixiNativeKataGoServiceError.libraryNotLinked
        }
        guard let resolved = modelStore.resolvedModel(for: spec) else {
          throw QixiNativeKataGoServiceError.modelMissing(spec.resourceName)
        }
        guard memoryPolicy.canLoad(spec) else {
          throw QixiNativeKataGoServiceError.insufficientDeviceMemory(memoryPolicy.report(for: spec))
        }
        try bridge.configureModel(
          engine.rawValue,
          resourceName: spec.resourceName,
          modelPath: resolved.fileURL.path,
          coreMLPackagePaths: resolved.coreMLPackageURLs.map(\.path),
          minimumMemoryMB: Int32(spec.minimumMemoryMB),
          recommendedMemoryMB: Int32(spec.recommendedMemoryMB),
          maximumMemoryMB: Int32(spec.maximumMemoryMB)
        )
      }
      try bridge.loadEngine(engine.rawValue)
      currentEngine = engine
      return BackendStatusResponse(
        engine: engine.rawValue,
        engineId: engine.rawValue,
        state: engine == .none ? "no engine loaded" : "native engine loaded",
        running: engine != .none,
        paused: false
      )
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  func submitCoreRequest(_ request: QixiCoreRequest) async throws -> QixiCoreBackendResult {
    do {
      return try submitCoreRequestSync(request)
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  func latestCoreSnapshot() async throws -> QixiCoreBackendResult {
    do {
      let responseJSON = try bridge.latestCoreSnapshotJSON()
      return try decodeCoreBackendResult(from: responseJSON)
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  func legalMoveMask() async throws -> QixiCoreLegalMoveMask {
    do {
      let responseJSON = try bridge.legalMoveMaskJSON()
      let data = try NativeKataGoBridgeResponseValidator.validatedData(
        from: responseJSON,
        maxResponseBytes: NativeKataGoBridgeResponseValidator.maxCoreResponseBytes
      )
      return try coreJSONDecoder.decode(QixiCoreLegalMoveMask.self, from: data)
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  func exportCoreState(to url: URL) async throws {
    do {
      try bridge.exportCoreState(to: url)
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  func importCoreState(from url: URL) async throws {
    do {
      try bridge.importCoreState(from: url)
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  private func submitCoreRequestSync(_ request: QixiCoreRequest) throws -> QixiCoreBackendResult {
    let data = try coreJSONEncoder.encode(request)
    let requestJSON = String(decoding: data, as: UTF8.self)
    let responseJSON = try bridge.submitCoreRequestJSON(requestJSON)
    return try decodeCoreBackendResult(from: responseJSON)
  }

  private func decodeCoreBackendResult(from responseJSON: String) throws -> QixiCoreBackendResult {
    let data = try NativeKataGoBridgeResponseValidator.validatedData(
      from: responseJSON,
      maxResponseBytes: NativeKataGoBridgeResponseValidator.maxCoreResponseBytes
    )
    do {
      return try coreJSONDecoder.decode(QixiCoreBackendResult.self, from: data)
    } catch {
      throw QixiNativeKataGoServiceError.invalidBridgeResponse(
        "Native Qixi core response could not be decoded: \(error)"
      )
    }
  }

  private func clearLoadedEngineBeforeRealEngineSwitch() throws {
    currentEngine = .none
    try bridge.loadEngine(AnalysisEngine.none.rawValue)
  }

  func analyze(
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse {
    try QixiAnalysisInputValidator.validate(
      moves: moves,
      setupStones: setupStones,
      maxVisits: maxVisits,
      komi: komi,
      rootNoise: rootNoise
    )
    do {
      let request = AnalysisRequest(
        moves: moves,
        setupStones: setupStones,
        maxVisits: maxVisits,
        komi: komi,
        rootNoise: rootNoise
      )
      let data = try JSONEncoder().encode(request)
      let requestJSON = String(decoding: data, as: UTF8.self)
      let responseJSON = try bridge.analyzeRequestJSON(requestJSON)
      let responseData = try NativeKataGoBridgeResponseValidator.validatedData(from: responseJSON)
      let decodedResponse: AnalysisResponse
      do {
        decodedResponse = try JSONDecoder().decode(AnalysisResponse.self, from: responseData)
      } catch {
        throw QixiNativeKataGoServiceError.invalidBridgeResponse(
          "Native KataGo adapter response could not be decoded: \(error)"
        )
      }
      var response = decodedResponse
      guard response.engine == currentEngine.rawValue else {
        throw QixiNativeKataGoServiceError.invalidRequest(
          "Native KataGo adapter returned engine \(response.engine) while \(currentEngine.rawValue) is loaded."
        )
      }
      response.positionKey = QixiPositionIdentity.cacheKey(
        engine: currentEngine,
        moves: moves,
        setupStones: setupStones,
        komi: komi,
        rootNoise: rootNoise
      )
      try QixiAnalysisResponseValidator.validate(response, expectedEngine: currentEngine)
      return response
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  func exportEngineTombstone(to url: URL) async throws {
    do {
      try bridge.exportTombstone(to: url)
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  func restoreEngineTombstone(from url: URL, for engine: AnalysisEngine) async throws {
    do {
      if engine == .none {
        try bridge.loadEngine(AnalysisEngine.none.rawValue)
        currentEngine = .none
        try bridge.restoreTombstone(from: url)
      } else {
        _ = try await setEngine(engine)
        do {
          try bridge.restoreTombstone(from: url)
        } catch {
          try? clearLoadedEngineBeforeRealEngineSwitch()
          throw error
        }
      }
    } catch {
      throw mapNativeBridgeError(error)
    }
  }

  private func mapNativeBridgeError(_ error: Error) -> Error {
    let nsError = error as NSError
    if nsError.domain == Self.nativeErrorDomain && nsError.code == Self.libraryNotLinkedErrorCode {
      return QixiNativeKataGoServiceError.libraryNotLinked
    }
    if nsError.domain == Self.nativeErrorDomain && nsError.code == Self.invalidRequestErrorCode {
      return QixiNativeKataGoServiceError.invalidRequest(nsError.localizedDescription)
    }
    return error
  }
}

enum NativeKataGoBridgeResponseValidator {
  static let maxResponseBytes = 1024 * 1024
  static let maxCoreResponseBytes = 8 * 1024 * 1024

  static func validatedData(
    from responseJSON: String,
    maxResponseBytes: Int = NativeKataGoBridgeResponseValidator.maxResponseBytes
  ) throws -> Data {
    let byteCount = responseJSON.utf8.count
    guard byteCount <= maxResponseBytes else {
      throw QixiNativeKataGoServiceError.invalidBridgeResponse(
        "Native KataGo adapter response body has \(byteCount) bytes, exceeding the \(maxResponseBytes) byte limit."
      )
    }
    let data = Data(responseJSON.utf8)
    try StrictJSONDuplicateKeyScanner(data: data, label: "Native KataGo adapter response").validateTopLevelObject()
    return data
  }
}

private struct StrictJSONDuplicateKeyScanner {
  let data: Data
  let label: String

  func validateTopLevelObject() throws {
    try data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      var parser = Parser(bytes: bytes, label: label)
      try parser.validateTopLevelObject()
    }
  }

  private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    let label: String
    var index = 0

    mutating func validateTopLevelObject() throws {
      skipWhitespace()
      guard peek() == UInt8(ascii: "{") else {
        throw invalid("must be a JSON object")
      }
      try parseObject()
      skipWhitespace()
      guard index == bytes.count else {
        throw invalid("must not contain trailing data")
      }
    }

    private mutating func parseValue() throws {
      skipWhitespace()
      guard let byte = peek() else {
        throw invalid("ended before a value")
      }
      switch byte {
      case UInt8(ascii: "{"):
        try parseObject()
      case UInt8(ascii: "["):
        try parseArray()
      case UInt8(ascii: "\""):
        _ = try parseString(decode: false)
      case UInt8(ascii: "t"):
        try consumeLiteral("true")
      case UInt8(ascii: "f"):
        try consumeLiteral("false")
      case UInt8(ascii: "n"):
        try consumeLiteral("null")
      case UInt8(ascii: "N"):
        if matches("NaN") {
          throw nonStandardConstant("NaN")
        }
        throw invalid("contains an invalid token")
      case UInt8(ascii: "I"):
        if matches("Infinity") {
          throw nonStandardConstant("Infinity")
        }
        throw invalid("contains an invalid token")
      case UInt8(ascii: "-"):
        if matches("-Infinity") {
          throw nonStandardConstant("-Infinity")
        }
        try parseNumber()
      case UInt8(ascii: "0")...UInt8(ascii: "9"):
        try parseNumber()
      default:
        throw invalid("contains an invalid token")
      }
    }

    private mutating func parseObject() throws {
      try consume(UInt8(ascii: "{"))
      skipWhitespace()
      var keys = Set<String>()
      if peek() == UInt8(ascii: "}") {
        index += 1
        return
      }
      while true {
        skipWhitespace()
        guard peek() == UInt8(ascii: "\"") else {
          throw invalid("object keys must be JSON strings")
        }
        let key = try parseString(decode: true)
        guard keys.insert(key).inserted else {
          throw QixiNativeKataGoServiceError.invalidBridgeResponse(
            "\(label) must not contain duplicate JSON key '\(key)'"
          )
        }
        skipWhitespace()
        try consume(UInt8(ascii: ":"))
        try parseValue()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
          index += 1
          return
        }
        try consume(UInt8(ascii: ","))
      }
    }

    private mutating func parseArray() throws {
      try consume(UInt8(ascii: "["))
      skipWhitespace()
      if peek() == UInt8(ascii: "]") {
        index += 1
        return
      }
      while true {
        try parseValue()
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
          index += 1
          return
        }
        try consume(UInt8(ascii: ","))
      }
    }

    private mutating func parseString(decode: Bool) throws -> String {
      let start = index
      try consume(UInt8(ascii: "\""))
      while index < bytes.count {
        let byte = bytes[index]
        if byte == UInt8(ascii: "\"") {
          index += 1
          guard decode else { return "" }
          do {
            return try JSONDecoder().decode(String.self, from: dataSlice(from: start, to: index))
          } catch {
            throw invalid("contains an invalid JSON string")
          }
        }
        if byte < 0x20 {
          throw invalid("contains an unescaped control character in a string")
        }
        if byte == UInt8(ascii: "\\") {
          index += 1
          guard let escaped = peek() else {
            throw invalid("ends inside a string escape")
          }
          switch escaped {
          case UInt8(ascii: "\""),
               UInt8(ascii: "\\"),
               UInt8(ascii: "/"),
               UInt8(ascii: "b"),
               UInt8(ascii: "f"),
               UInt8(ascii: "n"),
               UInt8(ascii: "r"),
               UInt8(ascii: "t"):
            index += 1
          case UInt8(ascii: "u"):
            index += 1
            for _ in 0..<4 {
              guard let hex = peek(), isHexDigit(hex) else {
                throw invalid("contains an invalid unicode escape")
              }
              index += 1
            }
          default:
            throw invalid("contains an invalid string escape")
          }
        } else {
          index += 1
        }
      }
      throw invalid("ends inside a string")
    }

    private mutating func parseNumber() throws {
      if peek() == UInt8(ascii: "-") {
        index += 1
      }
      guard let first = peek(), first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9") else {
        throw invalid("contains an invalid number")
      }
      if first == UInt8(ascii: "0") {
        index += 1
      } else {
        repeat {
          index += 1
        } while isDigit(peek())
      }
      if peek() == UInt8(ascii: ".") {
        index += 1
        guard isDigit(peek()) else {
          throw invalid("contains an invalid number")
        }
        repeat {
          index += 1
        } while isDigit(peek())
      }
      if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
        index += 1
        if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") {
          index += 1
        }
        guard isDigit(peek()) else {
          throw invalid("contains an invalid number")
        }
        repeat {
          index += 1
        } while isDigit(peek())
      }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
      guard matches(literal) else {
        throw invalid("contains an invalid token")
      }
      index += literal.utf8.count
    }

    private mutating func consume(_ expected: UInt8) throws {
      guard peek() == expected else {
        throw invalid("contains malformed JSON")
      }
      index += 1
    }

    private mutating func skipWhitespace() {
      while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
        index += 1
      }
    }

    private func matches(_ literal: String) -> Bool {
      guard index + literal.utf8.count <= bytes.count else { return false }
      var offset = 0
      for byte in literal.utf8 {
        guard bytes[index + offset] == byte else { return false }
        offset += 1
      }
      return true
    }

    private func peek() -> UInt8? {
      index < bytes.count ? bytes[index] : nil
    }

    private func dataSlice(from start: Int, to end: Int) -> Data {
      guard let baseAddress = bytes.baseAddress,
            start <= end,
            start >= 0,
            end <= bytes.count else {
        return Data()
      }
      return Data(bytes: baseAddress.advanced(by: start), count: end - start)
    }

    private func isDigit(_ byte: UInt8?) -> Bool {
      guard let byte else { return false }
      return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
      (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")) ||
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
    }

    private func invalid(_ message: String) -> QixiNativeKataGoServiceError {
      QixiNativeKataGoServiceError.invalidBridgeResponse("\(label) \(message).")
    }

    private func nonStandardConstant(_ value: String) -> QixiNativeKataGoServiceError {
      QixiNativeKataGoServiceError.invalidBridgeResponse(
        "\(label) must not contain non-standard JSON constant \(value)"
      )
    }
  }
}
