import Darwin
import Foundation
import UIKit

struct QixiCachedAnalysis: Codable, Equatable {
  var savedAt: Date
  var positionKey: String
  var winrate: Double
  var scoreMean: Double
  var visits: Int
  var candidates: [CandidateMove]
  var territory: [TerritoryPoint]
}

struct QixiAppSnapshot: Codable, Equatable {
  /// v2 adds optional rootNoise; v3 adds optional nextPlayer (root side-to-move / PL).
  static let currentSchemaVersion = 3

  var schemaVersion: Int = QixiAppSnapshot.currentSchemaVersion
  var savedAt: Date
  var saveReason: String
  var selectedEngine: AnalysisEngine
  var currentPly: Int
  var mainLine: [BoardMove]
  var recognizedSetupStones: [BoardSetupStone]?
  /// Explicit root side-to-move (photo recognition / SGF PL). Nil → infer from first move / Black.
  var nextPlayer: StoneColor?
  var komi: Double
  /// Wide-root noise; included in analysis cache keys — must survive restore/sync.
  var rootNoise: Double = QixiAnalysisLimits.defaultRootNoise
  var showTerritory: Bool
  var analysisByEngine: [String: [String: QixiCachedAnalysis]]

  enum CodingKeys: String, CodingKey {
    case schemaVersion, savedAt, saveReason, selectedEngine, currentPly, mainLine
    case recognizedSetupStones, nextPlayer, komi, rootNoise, showTerritory, analysisByEngine
  }

  init(
    schemaVersion: Int = QixiAppSnapshot.currentSchemaVersion,
    savedAt: Date,
    saveReason: String,
    selectedEngine: AnalysisEngine,
    currentPly: Int,
    mainLine: [BoardMove],
    recognizedSetupStones: [BoardSetupStone]? = nil,
    nextPlayer: StoneColor? = nil,
    komi: Double,
    rootNoise: Double = QixiAnalysisLimits.defaultRootNoise,
    showTerritory: Bool,
    analysisByEngine: [String: [String: QixiCachedAnalysis]]
  ) {
    self.schemaVersion = schemaVersion
    self.savedAt = savedAt
    self.saveReason = saveReason
    self.selectedEngine = selectedEngine
    self.currentPly = currentPly
    self.mainLine = mainLine
    self.recognizedSetupStones = recognizedSetupStones
    self.nextPlayer = nextPlayer
    self.komi = komi
    self.rootNoise = rootNoise
    self.showTerritory = showTerritory
    self.analysisByEngine = analysisByEngine
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? QixiAppSnapshot.currentSchemaVersion
    savedAt = try container.decode(Date.self, forKey: .savedAt)
    saveReason = try container.decode(String.self, forKey: .saveReason)
    selectedEngine = try container.decode(AnalysisEngine.self, forKey: .selectedEngine)
    currentPly = try container.decode(Int.self, forKey: .currentPly)
    mainLine = try container.decode([BoardMove].self, forKey: .mainLine)
    recognizedSetupStones = try container.decodeIfPresent([BoardSetupStone].self, forKey: .recognizedSetupStones)
    nextPlayer = try container.decodeIfPresent(StoneColor.self, forKey: .nextPlayer)
    komi = try container.decode(Double.self, forKey: .komi)
    rootNoise = try container.decodeIfPresent(Double.self, forKey: .rootNoise)
      ?? QixiAnalysisLimits.defaultRootNoise
    showTerritory = try container.decode(Bool.self, forKey: .showTerritory)
    analysisByEngine = try container.decode(
      [String: [String: QixiCachedAnalysis]].self,
      forKey: .analysisByEngine
    )
  }
}

enum QixiSnapshotValidationError: Error, Equatable {
  case illegalMainLine(ply: Int)
  case invalidCurrentPly(currentPly: Int, mainLineCount: Int)
  case invalidKomi(Double)
  case invalidAnalysisCache(engine: String, cacheKey: String, reason: String)
}

private struct QixiSemanticCacheKeyIdentity {
  var komi: Double
  var rootNoise: Double
  var setupStones: [BoardSetupStone]
  var nextPlayer: StoneColor?
  var history: [BoardMove]
}

extension QixiAppSnapshot {
  func hasSameRestorableState(as other: QixiAppSnapshot) -> Bool {
    selectedEngine == other.selectedEngine &&
      currentPly == other.currentPly &&
      mainLine == other.mainLine &&
      normalizedSetupStones(recognizedSetupStones) == normalizedSetupStones(other.recognizedSetupStones) &&
      nextPlayer == other.nextPlayer &&
      komi == other.komi &&
      rootNoise == other.rootNoise &&
      showTerritory == other.showTerritory &&
      analysisByEngine == other.analysisByEngine
  }

  private func normalizedSetupStones(_ setupStones: [BoardSetupStone]?) -> [BoardSetupStone] {
    guard let setupStones else { return [] }
    var bestByPoint: [Int: BoardSetupStone] = [:]
    for stone in setupStones where stone.x >= 0 && stone.x < QixiBoardPosition.boardSize &&
      stone.y >= 0 && stone.y < QixiBoardPosition.boardSize {
      bestByPoint[stone.id] = stone
    }
    return bestByPoint.values.sorted {
      if $0.y != $1.y { return $0.y < $1.y }
      if $0.x != $1.x { return $0.x < $1.x }
      return $0.color.rawValue < $1.color.rawValue
    }
  }
}

struct QixiLifecycleTombstone: Codable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int = QixiLifecycleTombstone.currentSchemaVersion
  var markedAt: Date
  var reason: String
  var snapshotSavedAt: Date
  var snapshotFilename: String
  var selectedEngine: AnalysisEngine
  var currentPly: Int
  var mainLineCount: Int
  var engineTombstoneFilename: String?
}

struct QixiRuntimeDiagnostic: Codable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int = QixiRuntimeDiagnostic.currentSchemaVersion
  var recordedAt: Date
  var event: String
  var success: Bool
  var selectedEngine: AnalysisEngine
  var analysisRuntime: String
  var backendBaseURL: String
  var message: String
}

struct QixiEngineTombstoneRestoreAudit: Codable, Equatable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int = QixiEngineTombstoneRestoreAudit.currentSchemaVersion
  var restoredAt: Date
  var tombstoneFilename: String
  var engine: AnalysisEngine
}

struct QixiEngineTombstoneExportAudit: Codable, Equatable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int = QixiEngineTombstoneExportAudit.currentSchemaVersion
  var exportedAt: Date
  var tombstoneFilename: String
  var engine: AnalysisEngine
  var reason: String
}

struct QixiMCTSStatePackageManifest: Codable, Equatable {
  static let currentSchemaVersion = 2
  static let kindValue = "qixi-mcts-state-package"

  var schemaVersion: Int = QixiMCTSStatePackageManifest.currentSchemaVersion
  var kind: String = QixiMCTSStatePackageManifest.kindValue
  var exportedAt: Date
  var snapshotFilename: String
  var engineTombstoneFilename: String?
  var coreStateFilename: String?
  var selectedEngine: AnalysisEngine
  var currentPly: Int
  var mainLineCount: Int
}

struct QixiImportedMCTSStatePackage {
  var snapshot: QixiAppSnapshot
  var engineTombstoneURL: URL?
  var coreStateURL: URL?
}

enum QixiStrictJSONError: Error, Equatable, LocalizedError {
  case documentTooLarge(label: String, bytes: Int, limit: Int)
  case malformed(label: String, message: String)
  case duplicateKey(label: String, key: String)
  case nonStandardConstant(label: String, value: String)
  case notRegularFile(label: String, path: String)

  var errorDescription: String? {
    switch self {
    case .documentTooLarge(let label, let bytes, let limit):
      return "\(label) has \(bytes) bytes, exceeding the \(limit) byte limit."
    case .malformed(let label, let message):
      return "\(label) \(message)."
    case .duplicateKey(let label, let key):
      return "\(label) must not contain duplicate JSON key '\(key)'."
    case .nonStandardConstant(let label, let value):
      return "\(label) must not contain non-standard JSON constant \(value)."
    case .notRegularFile(let label, let path):
      return "\(label) must be read from a regular file: \(path)."
    }
  }
}

enum QixiTrustedFilePath {
  static func createDirectoryForTrustedWrite(
    at directoryURL: URL,
    label: String,
    fileManager: FileManager = .default
  ) throws {
    try rejectSymbolicLinkComponents(in: directoryURL, label: label)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
    try rejectSymbolicLinkComponents(in: directoryURL, label: label)
  }

  static func writeProtectedDataAtomically(
    _ data: Data,
    to url: URL,
    label: String,
    fileProtection: FileProtectionType? = .completeUntilFirstUserAuthentication
  ) throws {
    try validateTrustedWriteTarget(url, label: label)
    let directoryURL = url.deletingLastPathComponent()
    let tempURL = directoryURL.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    try rejectSymbolicLinkComponents(in: tempURL, label: "\(label) temporary path")
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
    let descriptor = Darwin.open(tempURL.path, flags, mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "could not open exclusive no-follow temporary file: \(tempURL.path) (\(currentErrnoMessage()))"
      )
    }

    var shouldRemoveTemporaryFile = true
    do {
      defer { _ = Darwin.close(descriptor) }
      try writeAll(data, toFileDescriptor: descriptor, label: label, url: tempURL)
      try validateTemporaryFile(descriptor, expectedByteCount: data.count, label: label, url: tempURL)
      if let fileProtection {
        try? (tempURL as NSURL).setResourceValue(fileProtection, forKey: .fileProtectionKey)
      }
      try flushFileDescriptor(descriptor, label: label, url: tempURL)
      try validateTrustedWriteTarget(url, label: label)
      guard Darwin.rename(tempURL.path, url.path) == 0 else {
        throw QixiStrictJSONError.malformed(
          label: label,
          message: "could not atomically replace target: \(url.path) (\(currentErrnoMessage()))"
        )
      }
      try syncParentDirectory(directoryURL, label: label)
      shouldRemoveTemporaryFile = false
    } catch {
      if shouldRemoveTemporaryFile {
        try? FileManager.default.removeItem(at: tempURL)
      }
      throw error
    }
  }

  static func rejectSymbolicLinkComponents(in url: URL, label: String) throws {
    let components = url.standardizedFileURL.pathComponents
    guard !components.isEmpty else { return }
    var currentPath = components[0]
    for component in components.dropFirst() {
      currentPath = (currentPath as NSString).appendingPathComponent(component)
      let currentURL = URL(fileURLWithPath: currentPath)
      let values = try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true,
         !isAllowedPlatformSymlinkAlias(currentURL) {
        throw QixiStrictJSONError.malformed(
          label: label,
          message: "path must not contain symbolic links: \(currentURL.path)"
        )
      }
    }
  }

  private static func validateTrustedWriteTarget(_ url: URL, label: String) throws {
    try rejectSymbolicLinkComponents(in: url, label: label)
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "write target must not be a symbolic link: \(url.path)"
      )
    }
    if values?.isDirectory == true ||
      (FileManager.default.fileExists(atPath: url.path) && values?.isRegularFile != true) {
      throw QixiStrictJSONError.notRegularFile(label: label, path: url.path)
    }
  }

  private static func writeAll(_ data: Data, toFileDescriptor descriptor: Int32, label: String, url: URL) throws {
    try data.withUnsafeBytes { rawBuffer in
      var offset = 0
      while offset < rawBuffer.count {
        guard let baseAddress = rawBuffer.baseAddress else { break }
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if written < 0 {
          if errno == EINTR { continue }
          throw QixiStrictJSONError.malformed(
            label: label,
            message: "could not write temporary file: \(url.path) (\(currentErrnoMessage()))"
          )
        }
        guard written > 0 else {
          throw QixiStrictJSONError.malformed(
            label: label,
            message: "temporary file write made no progress: \(url.path)"
          )
        }
        offset += written
      }
    }
  }

  private static func validateTemporaryFile(
    _ descriptor: Int32,
    expectedByteCount: Int,
    label: String,
    url: URL
  ) throws {
    var statBuffer = stat()
    guard fstat(descriptor, &statBuffer) == 0 else {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "temporary file could not be inspected after writing: \(url.path) (\(currentErrnoMessage()))"
      )
    }
    guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
      throw QixiStrictJSONError.notRegularFile(label: label, path: url.path)
    }
    guard statBuffer.st_size >= 0,
          UInt64(statBuffer.st_size) == UInt64(expectedByteCount) else {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "temporary file byte count mismatch after writing: expected=\(expectedByteCount) actual=\(statBuffer.st_size) \(url.path)"
      )
    }
  }

  private static func flushFileDescriptor(_ descriptor: Int32, label: String, url: URL) throws {
    if fullSyncFileDescriptor(descriptor) {
      return
    }
    while Darwin.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "could not fsync temporary file before atomic replace: \(url.path) (\(currentErrnoMessage()))"
      )
    }
  }

  private static func syncParentDirectory(_ directoryURL: URL, label: String) throws {
    try rejectSymbolicLinkComponents(in: directoryURL, label: "\(label) parent directory")
    let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "could not open parent directory after atomic replace: \(directoryURL.path) (\(currentErrnoMessage()))"
      )
    }
    defer { _ = Darwin.close(descriptor) }
    var statBuffer = stat()
    guard fstat(descriptor, &statBuffer) == 0,
          (statBuffer.st_mode & S_IFMT) == S_IFDIR else {
      throw QixiStrictJSONError.notRegularFile(label: label, path: directoryURL.path)
    }
    if fullSyncFileDescriptor(descriptor) {
      return
    }
    while Darwin.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "could not fsync parent directory after atomic replace: \(directoryURL.path) (\(currentErrnoMessage()))"
      )
    }
  }

  private static func fullSyncFileDescriptor(_ descriptor: Int32) -> Bool {
    while true {
      if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
        return true
      }
      if errno == EINTR { continue }
      return false
    }
  }

  private static func currentErrnoMessage() -> String {
    String(cString: strerror(errno))
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
}

enum QixiStrictJSONDocumentValidator {
  static func validatedObjectData(_ data: Data, label: String, maxBytes: Int) throws -> Data {
    guard data.count <= maxBytes else {
      throw QixiStrictJSONError.documentTooLarge(label: label, bytes: data.count, limit: maxBytes)
    }
    try Scanner(data: data, label: label).validateTopLevelObject()
    return data
  }

  static func validatedObjectData(
    from url: URL,
    label: String,
    maxBytes: Int,
    fileManager: FileManager = .default
  ) throws -> Data {
    let data = try boundedData(
      from: url,
      label: label,
      maxBytes: maxBytes,
      fileManager: fileManager
    )
    return try validatedObjectData(data, label: label, maxBytes: maxBytes)
  }

  private static func boundedData(
    from url: URL,
    label: String,
    maxBytes: Int,
    fileManager: FileManager
  ) throws -> Data {
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(in: url, label: label)
    try validateRegularFileURL(url, label: label)
    if let byteCount = try fileByteCount(at: url, fileManager: fileManager),
       byteCount > maxBytes {
      throw QixiStrictJSONError.documentTooLarge(label: label, bytes: byteCount, limit: maxBytes)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let openedByteCount = try validateRegularOpenFile(
      handle,
      originalURL: url,
      label: label,
      maxBytes: maxBytes
    )
    if openedByteCount > maxBytes {
      throw QixiStrictJSONError.documentTooLarge(label: label, bytes: openedByteCount, limit: maxBytes)
    }
    let readLimit = maxBytes == Int.max ? maxBytes : maxBytes + 1
    let data = handle.readData(ofLength: readLimit)
    guard data.count <= maxBytes else {
      throw QixiStrictJSONError.documentTooLarge(label: label, bytes: data.count, limit: maxBytes)
    }
    guard data.count == openedByteCount else {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "opened-byte-count drift while reading: opened=\(openedByteCount) read=\(data.count) \(url.path)"
      )
    }
    return data
  }

  private static func validateRegularFileURL(_ url: URL, label: String) throws {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw QixiStrictJSONError.malformed(
          label: label,
          message: "path must not contain symbolic links: \(url.path)"
        )
      }
      guard values.isRegularFile == true, values.isDirectory != true else {
        throw QixiStrictJSONError.notRegularFile(label: label, path: url.path)
      }
    } catch let error as QixiStrictJSONError {
      throw error
    } catch {
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "file type could not be inspected before loading: \(url.path)"
      )
    }
  }

  private static func validateRegularOpenFile(
    _ handle: FileHandle,
    originalURL url: URL,
    label: String,
    maxBytes: Int
  ) throws -> Int {
    var statBuffer = stat()
    guard fstat(handle.fileDescriptor, &statBuffer) == 0 else {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "open file type could not be inspected before loading: \(url.path)"
      )
    }
    guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
      throw QixiStrictJSONError.notRegularFile(label: label, path: url.path)
    }
    guard statBuffer.st_size >= 0 else {
      throw QixiStrictJSONError.malformed(
        label: label,
        message: "open file byte count could not be inspected before loading: \(url.path)"
      )
    }
    guard UInt64(statBuffer.st_size) <= UInt64(Int.max) else {
      throw QixiStrictJSONError.documentTooLarge(label: label, bytes: Int.max, limit: maxBytes)
    }
    return Int(statBuffer.st_size)
  }

  private static func fileByteCount(at url: URL, fileManager: FileManager) throws -> Int? {
    do {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      if let size = attributes[.size] as? NSNumber {
        guard size.uint64Value <= UInt64(Int.max) else {
          return Int.max
        }
        return size.intValue
      }
      return nil
    } catch {
      return nil
    }
  }

  private struct Scanner {
    let data: Data
    let label: String

    func validateTopLevelObject() throws {
      try data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var parser = Parser(bytes: bytes, label: label)
        try parser.validateTopLevelObject()
      }
    }
  }

  private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    let label: String
    var index = 0

    mutating func validateTopLevelObject() throws {
      skipWhitespace()
      guard peek() == UInt8(ascii: "{") else {
        throw malformed("must be a JSON object")
      }
      try parseObject()
      skipWhitespace()
      guard index == bytes.count else {
        throw malformed("must not contain trailing data")
      }
    }

    private mutating func parseValue() throws {
      skipWhitespace()
      guard let byte = peek() else {
        throw malformed("ended before a value")
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
        if matches("NaN") { throw nonStandardConstant("NaN") }
        throw malformed("contains an invalid token")
      case UInt8(ascii: "I"):
        if matches("Infinity") { throw nonStandardConstant("Infinity") }
        throw malformed("contains an invalid token")
      case UInt8(ascii: "-"):
        if matches("-Infinity") { throw nonStandardConstant("-Infinity") }
        try parseNumber()
      case UInt8(ascii: "0")...UInt8(ascii: "9"):
        try parseNumber()
      default:
        throw malformed("contains an invalid token")
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
          throw malformed("object keys must be JSON strings")
        }
        let key = try parseString(decode: true)
        guard keys.insert(key).inserted else {
          throw QixiStrictJSONError.duplicateKey(label: label, key: key)
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
            throw malformed("contains an invalid JSON string")
          }
        }
        if byte < 0x20 {
          throw malformed("contains an unescaped control character in a string")
        }
        if byte == UInt8(ascii: "\\") {
          index += 1
          guard let escaped = peek() else {
            throw malformed("ends inside a string escape")
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
                throw malformed("contains an invalid unicode escape")
              }
              index += 1
            }
          default:
            throw malformed("contains an invalid string escape")
          }
        } else {
          index += 1
        }
      }
      throw malformed("ends inside a string")
    }

    private mutating func parseNumber() throws {
      if peek() == UInt8(ascii: "-") {
        index += 1
      }
      guard let first = peek(), first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9") else {
        throw malformed("contains an invalid number")
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
          throw malformed("contains an invalid number")
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
          throw malformed("contains an invalid number")
        }
        repeat {
          index += 1
        } while isDigit(peek())
      }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
      guard matches(literal) else {
        throw malformed("contains an invalid token")
      }
      index += literal.utf8.count
    }

    private mutating func consume(_ expected: UInt8) throws {
      guard peek() == expected else {
        throw malformed("contains malformed JSON")
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

    private func malformed(_ message: String) -> QixiStrictJSONError {
      QixiStrictJSONError.malformed(label: label, message: message)
    }

    private func nonStandardConstant(_ value: String) -> QixiStrictJSONError {
      QixiStrictJSONError.nonStandardConstant(label: label, value: value)
    }
  }
}

enum QixiSnapshotStore {
  static let snapshotFilename = "autosave.qixi-state.json"
  static let backupSnapshotFilename = "autosave.qixi-state.backup.json"
  static let maxSnapshotBytes = 16 * 1024 * 1024

  static var snapshotURL: URL {
    snapshotsDirectory.appendingPathComponent(snapshotFilename, isDirectory: false)
  }

  static var backupSnapshotURL: URL {
    snapshotsDirectory.appendingPathComponent(backupSnapshotFilename, isDirectory: false)
  }

  static var snapshotsDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Qixi", isDirectory: true)
  }

  static func load() -> QixiAppSnapshot? {
    loadNewestValidSnapshot(from: [snapshotURL, backupSnapshotURL])
  }

  private static func loadNewestValidSnapshot(from urls: [URL]) -> QixiAppSnapshot? {
    urls
      .compactMap(loadSnapshot)
      .max { lhs, rhs in lhs.savedAt < rhs.savedAt }
  }

  static func decode(from url: URL) throws -> QixiAppSnapshot? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      from: url,
      label: "Qixi app snapshot",
      maxBytes: maxSnapshotBytes
    )
    return try decodeValidatedObjectData(objectData)
  }

  private static func loadSnapshot(from url: URL) -> QixiAppSnapshot? {
    try? decode(from: url)
  }

  static func save(_ snapshot: QixiAppSnapshot) throws {
    let directory = snapshotsDirectory
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: directory,
      label: "Qixi app snapshot directory"
    )

    let data = try encode(snapshot)
    try writeProtected(data, to: snapshotURL)
    try writeProtected(data, to: backupSnapshotURL)
  }

  @discardableResult
  static func saveIfRestorableStateChanged(_ snapshot: QixiAppSnapshot) throws -> Bool {
    if storedCopiesAreValidAndRestorableEquivalent(to: snapshot) {
      return false
    }
    try save(snapshot)
    return true
  }

  private static func storedCopiesAreValidAndRestorableEquivalent(to snapshot: QixiAppSnapshot) -> Bool {
    [snapshotURL, backupSnapshotURL].allSatisfy { url in
      guard let persisted = loadSnapshot(from: url) else { return false }
      return snapshot.hasSameRestorableState(as: persisted)
    }
  }

  private static func writeProtected(_ data: Data, to url: URL) throws {
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: url,
      label: "Qixi app snapshot path"
    )
  }

  static func encode(_ snapshot: QixiAppSnapshot) throws -> Data {
    try validate(snapshot)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
  }

  static func decode(_ data: Data) throws -> QixiAppSnapshot? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      data,
      label: "Qixi app snapshot",
      maxBytes: maxSnapshotBytes
    )
    return try decodeValidatedObjectData(objectData)
  }

  private static func decodeValidatedObjectData(_ objectData: Data) throws -> QixiAppSnapshot? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(QixiAppSnapshot.self, from: objectData)
    guard snapshot.schemaVersion == QixiAppSnapshot.currentSchemaVersion else { return nil }
    guard (try? validate(snapshot)) != nil else { return nil }
    return snapshot
  }

  private static func validate(_ snapshot: QixiAppSnapshot) throws {
    guard snapshot.currentPly >= 0 && snapshot.currentPly <= snapshot.mainLine.count else {
      throw QixiSnapshotValidationError.invalidCurrentPly(
        currentPly: snapshot.currentPly,
        mainLineCount: snapshot.mainLine.count
      )
    }
    guard QixiAnalysisLimits.isValidKomi(snapshot.komi) else {
      throw QixiSnapshotValidationError.invalidKomi(snapshot.komi)
    }
    let setupStones = snapshot.recognizedSetupStones ?? []
    if QixiBoardPosition.firstInvalidSetupStoneIndex(in: setupStones) != nil {
      throw QixiSnapshotValidationError.invalidAnalysisCache(
        engine: snapshot.selectedEngine.rawValue,
        cacheKey: "",
        reason: "invalid recognized setup stones"
      )
    }
    if let illegalIndex = QixiBoardPosition.firstIllegalMoveIndex(in: snapshot.mainLine, setupStones: setupStones) {
      throw QixiSnapshotValidationError.illegalMainLine(ply: illegalIndex + 1)
    }
    for (engine, cacheByPosition) in snapshot.analysisByEngine {
      guard AnalysisEngine(rawValue: engine) != nil else {
        throw QixiSnapshotValidationError.invalidAnalysisCache(
          engine: engine,
          cacheKey: "",
          reason: "unknown engine"
        )
      }
      for (cacheKey, cache) in cacheByPosition {
        try validate(cache, engine: engine, cacheKey: cacheKey)
      }
    }
  }

  private static func validate(_ cache: QixiCachedAnalysis, engine: String, cacheKey: String) throws {
    func fail(_ reason: String) throws -> Never {
      throw QixiSnapshotValidationError.invalidAnalysisCache(
        engine: engine,
        cacheKey: cacheKey,
        reason: reason
      )
    }

    guard !cacheKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      try fail("empty cache key")
    }
    guard !cache.positionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      try fail("empty position key")
    }
    guard cache.positionKey == cacheKey else {
      try fail("position key does not match cache key")
    }
    guard cacheKey.hasPrefix("\(engine)|") else {
      try fail("cache key engine prefix does not match analysis engine")
    }
    guard semanticCacheKeyIdentity(cacheKey, engine: engine) != nil else {
      try fail("malformed semantic cache key")
    }
    guard cache.winrate.isFinite && cache.winrate >= 0.0 && cache.winrate <= 1.0 else {
      try fail("invalid cached winrate")
    }
    guard cache.scoreMean.isFinite else {
      try fail("invalid cached score mean")
    }
    guard cache.visits >= 0 else {
      try fail("invalid cached visits")
    }

    var candidatePoints = Set<Int>()
    for (index, candidate) in cache.candidates.enumerated() {
      guard isOnBoard(x: candidate.x, y: candidate.y) else {
        try fail("candidate \(index) is off board")
      }
      guard candidatePoints.insert(boardIndex(x: candidate.x, y: candidate.y)).inserted else {
        try fail("candidate \(index) duplicates a previous point")
      }
      guard candidate.rank > 0 else {
        try fail("candidate \(index) has invalid rank")
      }
      guard candidate.winrate.isFinite && candidate.winrate >= 0.0 && candidate.winrate <= 1.0 else {
        try fail("candidate \(index) has invalid winrate")
      }
      guard candidate.visits >= 0 else {
        try fail("candidate \(index) has invalid visits")
      }
      guard candidate.scoreMean.isFinite else {
        try fail("candidate \(index) has invalid score mean")
      }
    }

    var territoryPoints = Set<Int>()
    for (index, point) in cache.territory.enumerated() {
      guard isOnBoard(x: point.x, y: point.y) else {
        try fail("territory \(index) is off board")
      }
      guard territoryPoints.insert(boardIndex(x: point.x, y: point.y)).inserted else {
        try fail("territory \(index) duplicates a previous point")
      }
      guard point.ownership.isFinite && point.ownership >= -1.0 && point.ownership <= 1.0 else {
        try fail("territory \(index) has invalid ownership")
      }
    }
  }

  private static func isOnBoard(x: Int, y: Int) -> Bool {
    x >= 0 && x < QixiBoardPosition.boardSize && y >= 0 && y < QixiBoardPosition.boardSize
  }

  private static func boardIndex(x: Int, y: Int) -> Int {
    y * QixiBoardPosition.boardSize + x
  }

  private static func semanticCacheKeyIdentity(_ cacheKey: String, engine: String) -> QixiSemanticCacheKeyIdentity? {
    let prefix = "\(engine)|rules:\(QixiPositionIdentity.fixedRules)|komiBits:"
    guard cacheKey.hasPrefix(prefix) else { return nil }

    let afterPrefix = String(cacheKey.dropFirst(prefix.count))
    guard let rootNoiseRange = afterPrefix.range(of: "|rootNoiseBits:") else { return nil }
    let komiBits = String(afterPrefix[..<rootNoiseRange.lowerBound])
    guard let komi = decodedCanonicalDoubleBits(komiBits),
          QixiAnalysisLimits.isValidKomi(komi) else {
      return nil
    }

    let afterRootNoiseMarker = String(afterPrefix[rootNoiseRange.upperBound...])
    let rootNoiseBits: String
    let setupStones: [BoardSetupStone]
    let nextPlayer: StoneColor?
    let history: String
    if let setupRange = afterRootNoiseMarker.range(of: "|setup:") {
      rootNoiseBits = String(afterRootNoiseMarker[..<setupRange.lowerBound])
      let afterSetupMarker = String(afterRootNoiseMarker[setupRange.upperBound...])
      guard let nextRange = afterSetupMarker.range(of: "|next:") else { return nil }
      guard let historyRange = afterSetupMarker.range(of: "|history:") else { return nil }
      guard nextRange.lowerBound < historyRange.lowerBound else { return nil }
      let setupText = String(afterSetupMarker[..<nextRange.lowerBound])
      let nextText = String(afterSetupMarker[nextRange.upperBound..<historyRange.lowerBound])
      guard !nextText.isEmpty, !nextText.contains("|"),
            let decodedNextPlayer = StoneColor(rawValue: nextText),
            let decodedSetupStones = decodedSetupStones(setupText),
            QixiBoardPosition.firstInvalidSetupStoneIndex(in: decodedSetupStones) == nil else {
        return nil
      }
      setupStones = decodedSetupStones
      nextPlayer = decodedNextPlayer
      history = String(afterSetupMarker[historyRange.upperBound...])
    } else {
      guard let historyRange = afterRootNoiseMarker.range(of: "|history:") else { return nil }
      rootNoiseBits = String(afterRootNoiseMarker[..<historyRange.lowerBound])
      setupStones = []
      nextPlayer = nil
      history = String(afterRootNoiseMarker[historyRange.upperBound...])
    }
    guard let rootNoise = decodedCanonicalDoubleBits(rootNoiseBits),
          QixiAnalysisLimits.isValidRootNoise(rootNoise) else {
      return nil
    }

    guard !history.contains("|"),
          let moves = decodedHistory(history) else {
      return nil
    }
    guard QixiBoardPosition.firstIllegalMoveIndex(in: moves, setupStones: setupStones) == nil else {
      return nil
    }
    if let nextPlayer {
      // Empty history may legally be White to play (setup + W first). Non-empty history
      // is fully determined by the last move color.
      if moves.isEmpty {
        guard nextPlayer == .black || nextPlayer == .white else { return nil }
      } else if nextPlayer != QixiBoardPosition.nextPlayer(after: moves) {
        return nil
      }
    }
    return QixiSemanticCacheKeyIdentity(
      komi: komi,
      rootNoise: rootNoise,
      setupStones: setupStones,
      nextPlayer: nextPlayer,
      history: moves
    )
  }

  private static func decodedCanonicalDoubleBits(_ value: String) -> Double? {
    guard isCanonicalUInt64HexBits(value),
          let bits = UInt64(value, radix: 16) else {
      return nil
    }
    return Double(bitPattern: bits)
  }

  private static func isCanonicalUInt64HexBits(_ value: String) -> Bool {
    guard !value.isEmpty && value.utf8.count <= 16 else { return false }
    if value.utf8.count > 1 && value.utf8.first == UInt8(ascii: "0") {
      return false
    }
    return value.utf8.allSatisfy { byte in
      (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }
  }

  private static func decodedHistory(_ history: String) -> [BoardMove]? {
    guard !history.isEmpty else { return [] }
    var moves: [BoardMove] = []
    let entries = history.split(separator: ";", omittingEmptySubsequences: false)
    moves.reserveCapacity(entries.count)
    for (index, entry) in entries.enumerated() {
      guard !entry.isEmpty else { return nil }
      let fields = entry.split(separator: ":", omittingEmptySubsequences: false)
      guard fields.count == 3 || fields.count == 4 else { return nil }
      guard fields[0] == Substring(String(index)) else { return nil }
      guard let color = StoneColor(rawValue: String(fields[1])) else { return nil }
      if fields.count == 3 {
        guard fields[2] == "pass" else { return nil }
        moves.append(BoardMove(pass: color))
      } else {
        guard let x = Int(fields[2]),
              let y = Int(fields[3]),
              isOnBoard(x: x, y: y) else {
          return nil
        }
        moves.append(BoardMove(color: color, x: x, y: y))
      }
    }
    return moves
  }

  private static func decodedSetupStones(_ setup: String) -> [BoardSetupStone]? {
    guard !setup.isEmpty else { return [] }
    var stones: [BoardSetupStone] = []
    var seen = Set<Int>()
    let entries = setup.split(separator: ";", omittingEmptySubsequences: false)
    stones.reserveCapacity(entries.count)
    for entry in entries {
      guard !entry.isEmpty else { return nil }
      let fields = entry.split(separator: ":", omittingEmptySubsequences: false)
      guard fields.count == 3,
            let color = StoneColor(rawValue: String(fields[0])),
            let x = Int(fields[1]),
            let y = Int(fields[2]),
            isOnBoard(x: x, y: y) else {
        return nil
      }
      let stone = BoardSetupStone(color: color, x: x, y: y)
      guard seen.insert(stone.id).inserted else { return nil }
      stones.append(stone)
    }
    return stones
  }
}

enum QixiRuntimeDiagnosticStore {
  static let diagnosticFilename = "runtime-diagnostics.qixi-state.json"
  static let maxDiagnosticBytes = 64 * 1024

  static var diagnosticURL: URL {
    QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(diagnosticFilename, isDirectory: false)
  }

  static func record(_ diagnostic: QixiRuntimeDiagnostic) throws {
    let directory = QixiSnapshotStore.snapshotsDirectory
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: directory,
      label: "Qixi runtime diagnostics directory"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(diagnostic)
    guard data.count <= maxDiagnosticBytes else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi runtime diagnostics",
        message: "encoded diagnostic exceeds \(maxDiagnosticBytes) bytes"
      )
    }
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: diagnosticURL,
      label: "Qixi runtime diagnostics path"
    )
  }
}

enum QixiEngineTombstoneStore {
  static let tombstoneFilename = "native-engine-tombstone.qixi-native"
  static let exportAuditFilename = "native-engine-tombstone.export.json"
  static let restoreAuditFilename = "native-engine-tombstone.restore.json"
  static let maxAuditBytes = 64 * 1024

  static var tombstoneURL: URL {
    QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(tombstoneFilename, isDirectory: false)
  }

  static var restoreAuditURL: URL {
    QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(restoreAuditFilename, isDirectory: false)
  }

  static var exportAuditURL: URL {
    QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(exportAuditFilename, isDirectory: false)
  }

  static func markExported(engine: AnalysisEngine, reason: String, exportedAt: Date = Date()) throws {
    let audit = QixiEngineTombstoneExportAudit(
      exportedAt: exportedAt,
      tombstoneFilename: tombstoneFilename,
      engine: engine,
      reason: reason
    )
    let directory = QixiSnapshotStore.snapshotsDirectory
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: directory,
      label: "Qixi native engine audit directory"
    )
    let data = try encode(audit)
    try writeProtected(data, to: exportAuditURL)
  }

  static func markRestored(engine: AnalysisEngine, restoredAt: Date = Date()) throws {
    let audit = QixiEngineTombstoneRestoreAudit(
      restoredAt: restoredAt,
      tombstoneFilename: tombstoneFilename,
      engine: engine
    )
    let directory = QixiSnapshotStore.snapshotsDirectory
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: directory,
      label: "Qixi native engine audit directory"
    )
    let data = try encode(audit)
    try writeProtected(data, to: restoreAuditURL)
  }

  static func loadExportAudit() -> QixiEngineTombstoneExportAudit? {
    do {
      return try decodeExportAudit(from: exportAuditURL)
    } catch {
      return nil
    }
  }

  static func loadRestoreAudit() -> QixiEngineTombstoneRestoreAudit? {
    do {
      return try decode(from: restoreAuditURL)
    } catch {
      return nil
    }
  }

  static func encode(_ audit: QixiEngineTombstoneRestoreAudit) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(audit)
  }

  static func encode(_ audit: QixiEngineTombstoneExportAudit) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(audit)
  }

  static func decode(_ data: Data) throws -> QixiEngineTombstoneRestoreAudit? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      data,
      label: "Qixi native engine restore audit",
      maxBytes: maxAuditBytes
    )
    return try decodeValidatedRestoreAudit(objectData)
  }

  static func decode(from url: URL) throws -> QixiEngineTombstoneRestoreAudit? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      from: url,
      label: "Qixi native engine restore audit",
      maxBytes: maxAuditBytes
    )
    return try decodeValidatedRestoreAudit(objectData)
  }

  private static func decodeValidatedRestoreAudit(_ objectData: Data) throws -> QixiEngineTombstoneRestoreAudit? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let audit = try decoder.decode(QixiEngineTombstoneRestoreAudit.self, from: objectData)
    guard audit.schemaVersion == QixiEngineTombstoneRestoreAudit.currentSchemaVersion else { return nil }
    return audit
  }

  static func decodeExportAudit(_ data: Data) throws -> QixiEngineTombstoneExportAudit? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      data,
      label: "Qixi native engine export audit",
      maxBytes: maxAuditBytes
    )
    return try decodeValidatedExportAudit(objectData)
  }

  static func decodeExportAudit(from url: URL) throws -> QixiEngineTombstoneExportAudit? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      from: url,
      label: "Qixi native engine export audit",
      maxBytes: maxAuditBytes
    )
    return try decodeValidatedExportAudit(objectData)
  }

  private static func decodeValidatedExportAudit(_ objectData: Data) throws -> QixiEngineTombstoneExportAudit? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let audit = try decoder.decode(QixiEngineTombstoneExportAudit.self, from: objectData)
    guard audit.schemaVersion == QixiEngineTombstoneExportAudit.currentSchemaVersion else { return nil }
    return audit
  }

  private static func writeProtected(_ data: Data, to url: URL) throws {
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: url,
      label: "Qixi native engine audit path"
    )
  }
}

enum QixiMCTSStatePackageStore {
  /// User-visible archives use a name ending in `.png` so Files / iCloud Drive
  /// classify them as images and show the board thumbnail. Legacy `.qixi-mcts`
  /// directory/file packages remain openable.
  static let packageExtension = "qixi.png"
  static let legacyPackageExtensions = ["qixi-mcts"]
  static let contentTypeIdentifier = "com.zyx.qixi.mcts-state"

  static var allPackageFilenameSuffixes: [String] {
    [packageExtension] + legacyPackageExtensions
  }

  static func filenameLooksLikePackage(_ name: String) -> Bool {
    let lower = name.lowercased()
    return allPackageFilenameSuffixes.contains { lower.hasSuffix(".\($0)") }
  }
  static let manifestFilename = "manifest.json"
  static let snapshotFilename = "snapshot.json"
  static let engineTombstoneFilename = QixiEngineTombstoneStore.tombstoneFilename
  static let coreStateFilename = "core-state.bin"
  /// Final board position preview (optional; ignored by older loaders).
  static let thumbnailFilename = "thumbnail.png"
  /// System package preview path (Files / Quick Look look here for document icons).
  static let quickLookDirectoryName = "QuickLook"
  static let quickLookThumbnailFilename = "Thumbnail.png"
  /// Optional main-line SGF colocated in the package for portable game record.
  static let gameSGFFilename = "game.sgf"
  static let maxManifestBytes = 64 * 1024
  static let maxTombstoneBytes: UInt64 = 256 * 1024 * 1024
  static let maxCoreStateBytes: UInt64 = 512 * 1024 * 1024
  /// Magic trailer after a board PNG so Files shows a real board icon while the
  /// payload still carries snapshot / core-state / SGF. Directory packages remain
  /// readable for older archives.
  static let imageDocumentMagic = Data("QIXIMC01".utf8)
  static let imageDocumentMaxBytes: UInt64 = 768 * 1024 * 1024

  static func freshTemporaryPackageURL(baseName: String? = nil) throws -> URL {
    let leaf = baseName.flatMap { name -> String? in
      let cleaned = QixiSyncStore.sanitizeFileBaseName(name)
      return cleaned.isEmpty ? nil : cleaned
    } ?? "qixi-state-\(UUID().uuidString)"
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(leaf)
      .appendingPathExtension(packageExtension)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Converts a finished directory package into a single regular file whose leading
  /// bytes are a board PNG (so Files / iCloud Drive render distinct icons).
  /// Replaces `packageURL` in place (directory → file).
  static func sealDirectoryPackageAsImageDocument(_ packageURL: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
      // Already a file — leave as-is (may already be sealed).
      return
    }
    let pngCandidates = [
      quickLookThumbnailURL(in: packageURL),
      thumbnailURL(in: packageURL),
    ]
    guard let pngURL = pngCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let pngData = try? Data(contentsOf: pngURL),
          pngData.count >= 24,
          pngData.starts(with: Data([0x89, 0x50, 0x4E, 0x47]))
    else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "cannot seal image document without a board thumbnail.png"
      )
    }

    let memberNames = [
      manifestFilename,
      snapshotFilename,
      coreStateFilename,
      gameSGFFilename,
      thumbnailFilename,
      engineTombstoneFilename,
    ]
    var sections: [(String, Data)] = []
    for name in memberNames {
      let url = packageURL.appendingPathComponent(name, isDirectory: false)
      guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            !data.isEmpty
      else { continue }
      sections.append((name, data))
    }
    guard sections.contains(where: { $0.0 == snapshotFilename }) else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "cannot seal image document without snapshot.json"
      )
    }

    var payload = Data()
    payload.reserveCapacity(pngData.count + 64 + sections.reduce(0) { $0 + $1.1.count + 32 })
    payload.append(pngData)
    payload.append(imageDocumentMagic)
    var sectionCount = UInt32(sections.count).littleEndian
    withUnsafeBytes(of: &sectionCount) { payload.append(contentsOf: $0) }
    for (name, data) in sections {
      let nameData = Data(name.utf8)
      var nameLen = UInt16(nameData.count).littleEndian
      withUnsafeBytes(of: &nameLen) { payload.append(contentsOf: $0) }
      payload.append(nameData)
      var dataLen = UInt64(data.count).littleEndian
      withUnsafeBytes(of: &dataLen) { payload.append(contentsOf: $0) }
      payload.append(data)
    }
    guard UInt64(payload.count) <= imageDocumentMaxBytes else {
      throw QixiStrictJSONError.documentTooLarge(
        label: "Qixi MCTS image document",
        bytes: payload.count,
        limit: Int(imageDocumentMaxBytes)
      )
    }

    let tempFile = packageURL.deletingLastPathComponent()
      .appendingPathComponent(".seal-\(UUID().uuidString).\(packageExtension)", isDirectory: false)
    try payload.write(to: tempFile, options: [.atomic])
    try FileManager.default.removeItem(at: packageURL)
    try FileManager.default.moveItem(at: tempFile, to: packageURL)
  }

  /// If `packageURL` is a sealed image document, expand members into a temp directory
  /// and return that directory (caller owns cleanup). Directory packages return as-is.
  static func materializePackageDirectory(from packageURL: URL) throws -> (url: URL, isTemporary: Bool) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "path does not exist"
      )
    }
    if isDirectory.boolValue {
      return (packageURL, false)
    }

    let data = try Data(contentsOf: packageURL, options: [.mappedIfSafe])
    guard data.count > imageDocumentMagic.count + 8,
          data.starts(with: Data([0x89, 0x50, 0x4E, 0x47]))
    else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "regular file is not a Qixi image document or directory package"
      )
    }
    // Find magic after PNG IEND to tolerate minor PNG encoder variance; fall back to last occurrence.
    guard let magicRange = data.range(of: imageDocumentMagic) else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "image document missing QIXIMC01 payload marker"
      )
    }
    var cursor = magicRange.upperBound
    func readLEInteger(byteCount: Int) throws -> UInt64 {
      guard cursor + byteCount <= data.count else {
        throw QixiStrictJSONError.malformed(
          label: "Qixi MCTS image document",
          message: "truncated integer (\(byteCount) bytes)"
        )
      }
      var value: UInt64 = 0
      for i in 0..<byteCount {
        value |= UInt64(data[cursor + i]) << (8 * i)
      }
      cursor += byteCount
      return value
    }
    func readU32() throws -> UInt32 { UInt32(try readLEInteger(byteCount: 4)) }
    func readU16() throws -> UInt16 { UInt16(try readLEInteger(byteCount: 2)) }
    func readU64() throws -> UInt64 { try readLEInteger(byteCount: 8) }

    let sectionCount = try readU32()
    guard sectionCount > 0 && sectionCount < 64 else {
      throw QixiStrictJSONError.malformed(label: "Qixi MCTS image document", message: "invalid section count")
    }
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("qixi-unseal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    do {
      for _ in 0..<sectionCount {
        let nameLen = Int(try readU16())
        guard nameLen > 0, nameLen < 512, cursor + nameLen <= data.count else {
          throw QixiStrictJSONError.malformed(label: "Qixi MCTS image document", message: "invalid section name")
        }
        let nameData = data.subdata(in: cursor..<(cursor + nameLen))
        cursor += nameLen
        guard let name = String(data: nameData, encoding: .utf8),
              !name.contains("/"), !name.contains("..")
        else {
          throw QixiStrictJSONError.malformed(label: "Qixi MCTS image document", message: "invalid section name encoding")
        }
        let dataLen = Int(try readU64())
        guard dataLen >= 0, cursor + dataLen <= data.count else {
          throw QixiStrictJSONError.malformed(label: "Qixi MCTS image document", message: "invalid section data length")
        }
        let section = data.subdata(in: cursor..<(cursor + dataLen))
        cursor += dataLen
        try section.write(
          to: tempDir.appendingPathComponent(name, isDirectory: false),
          options: [.atomic]
        )
      }
      // Ensure a root thumbnail exists for loaders / re-export even if only payload had it.
      let rootThumb = tempDir.appendingPathComponent(thumbnailFilename, isDirectory: false)
      if !FileManager.default.fileExists(atPath: rootThumb.path) {
        // Leading PNG is always the board image.
        try data.subdata(in: 0..<magicRange.lowerBound).write(to: rootThumb, options: [.atomic])
      }
      return (tempDir, true)
    } catch {
      try? FileManager.default.removeItem(at: tempDir)
      throw error
    }
  }

  static func snapshotURL(in packageURL: URL) -> URL {
    packageURL.appendingPathComponent(snapshotFilename, isDirectory: false)
  }

  static func engineTombstoneURL(in packageURL: URL) -> URL {
    packageURL.appendingPathComponent(engineTombstoneFilename, isDirectory: false)
  }

  static func coreStateURL(in packageURL: URL) -> URL {
    packageURL.appendingPathComponent(coreStateFilename, isDirectory: false)
  }

  static func thumbnailURL(in packageURL: URL) -> URL {
    packageURL.appendingPathComponent(thumbnailFilename, isDirectory: false)
  }

  /// Board preview for Open list rows (directory package, sealed image document, or plain PNG).
  static func previewThumbnailImage(from packageURL: URL, maxPixelSize: CGFloat = 160) -> UIImage? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
      return nil
    }
    if isDirectory.boolValue {
      let candidates = [quickLookThumbnailURL(in: packageURL), thumbnailURL(in: packageURL)]
      for url in candidates {
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
          return scaledPreview(image, maxPixelSize: maxPixelSize)
        }
      }
      return nil
    }
    // Sealed `.qixi.png` begins with a board PNG; UIImage stops at IEND.
    if let image = UIImage(contentsOfFile: packageURL.path) {
      return scaledPreview(image, maxPixelSize: maxPixelSize)
    }
    if let data = try? Data(contentsOf: packageURL, options: [.mappedIfSafe]),
       data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])),
       let image = UIImage(data: data) {
      return scaledPreview(image, maxPixelSize: maxPixelSize)
    }
    return nil
  }

  private static func scaledPreview(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage {
    let maxSide = max(image.size.width, image.size.height)
    guard maxSide > maxPixelSize, maxSide > 0 else { return image }
    let scale = maxPixelSize / maxSide
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = true
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }

  static func quickLookDirectoryURL(in packageURL: URL) -> URL {
    packageURL.appendingPathComponent(quickLookDirectoryName, isDirectory: true)
  }

  static func quickLookThumbnailURL(in packageURL: URL) -> URL {
    quickLookDirectoryURL(in: packageURL)
      .appendingPathComponent(quickLookThumbnailFilename, isDirectory: false)
  }

  static func gameSGFURL(in packageURL: URL) -> URL {
    packageURL.appendingPathComponent(gameSGFFilename, isDirectory: false)
  }

  static func writeSnapshot(_ snapshot: QixiAppSnapshot, to packageURL: URL) throws {
    let data = try QixiSnapshotStore.encode(snapshot)
    try data.write(to: snapshotURL(in: packageURL), options: [.atomic])
  }

  /// Writes board preview for app use (`thumbnail.png`) and for Files/Quick Look
  /// (`QuickLook/Thumbnail.png`). Without the Quick Look path, every package shows
  /// the same generic document icon.
  static func writeThumbnailPNG(_ data: Data, to packageURL: URL) throws {
    try data.write(to: thumbnailURL(in: packageURL), options: [.atomic])
    let qlDir = quickLookDirectoryURL(in: packageURL)
    try FileManager.default.createDirectory(at: qlDir, withIntermediateDirectories: true)
    try data.write(to: quickLookThumbnailURL(in: packageURL), options: [.atomic])
  }

  static func writeGameSGF(_ text: String, to packageURL: URL) throws {
    guard let data = text.data(using: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    try data.write(to: gameSGFURL(in: packageURL), options: [.atomic])
  }

  static func writeManifest(
    snapshot: QixiAppSnapshot,
    includesEngineTombstone: Bool,
    includesCoreState: Bool = false,
    to packageURL: URL,
    exportedAt: Date = Date()
  ) throws {
    let manifest = QixiMCTSStatePackageManifest(
      exportedAt: exportedAt,
      snapshotFilename: snapshotFilename,
      engineTombstoneFilename: includesEngineTombstone ? engineTombstoneFilename : nil,
      coreStateFilename: includesCoreState ? coreStateFilename : nil,
      selectedEngine: snapshot.selectedEngine,
      currentPly: snapshot.currentPly,
      mainLineCount: snapshot.mainLine.count
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(manifest)
    guard data.count <= maxManifestBytes else {
      throw QixiStrictJSONError.documentTooLarge(
        label: "Qixi MCTS state manifest",
        bytes: data.count,
        limit: maxManifestBytes
      )
    }
    try data.write(to: packageURL.appendingPathComponent(manifestFilename), options: [.atomic])
  }

  static func loadPackage(from packageURL: URL) throws -> QixiImportedMCTSStatePackage {
    let materialized = try materializePackageDirectory(from: packageURL)
    let root = materialized.url
    defer {
      if materialized.isTemporary {
        try? FileManager.default.removeItem(at: root)
      }
    }
    try validatePackageURL(root)
    let manifest = try loadManifest(from: root)
    guard manifest.snapshotFilename == snapshotFilename else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "uses an unexpected snapshot filename"
      )
    }
    guard let snapshot = try QixiSnapshotStore.decode(from: snapshotURL(in: root)) else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "contains an unsupported snapshot"
      )
    }
    guard manifest.selectedEngine == snapshot.selectedEngine,
          manifest.currentPly == snapshot.currentPly,
          manifest.mainLineCount == snapshot.mainLine.count else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "manifest does not match the embedded snapshot"
      )
    }

    // Core-state / tombstone must outlive this function for import — copy out of temp.
    let tombstoneURL: URL?
    if let tombstoneFilename = manifest.engineTombstoneFilename {
      guard tombstoneFilename == engineTombstoneFilename else {
        throw QixiStrictJSONError.malformed(
          label: "Qixi MCTS state package",
          message: "uses an unexpected engine tombstone filename"
        )
      }
      let url = engineTombstoneURL(in: root)
      try validateTombstoneURL(url)
      if materialized.isTemporary {
        let durable = FileManager.default.temporaryDirectory
          .appendingPathComponent("qixi-import-tombstone-\(UUID().uuidString).bin", isDirectory: false)
        try FileManager.default.copyItem(at: url, to: durable)
        tombstoneURL = durable
      } else {
        tombstoneURL = url
      }
    } else {
      tombstoneURL = nil
    }

    let importedCoreStateURL: URL?
    if let coreFilename = manifest.coreStateFilename {
      guard coreFilename == coreStateFilename else {
        throw QixiStrictJSONError.malformed(
          label: "Qixi MCTS state package",
          message: "uses an unexpected core state filename"
        )
      }
      let url = coreStateURL(in: root)
      try validateCoreStateURL(url)
      if materialized.isTemporary {
        let durable = FileManager.default.temporaryDirectory
          .appendingPathComponent("qixi-import-core-\(UUID().uuidString).bin", isDirectory: false)
        try FileManager.default.copyItem(at: url, to: durable)
        importedCoreStateURL = durable
      } else {
        importedCoreStateURL = url
      }
    } else {
      importedCoreStateURL = nil
    }
    return QixiImportedMCTSStatePackage(
      snapshot: snapshot,
      engineTombstoneURL: tombstoneURL,
      coreStateURL: importedCoreStateURL
    )
  }

  private static func loadManifest(from packageURL: URL) throws -> QixiMCTSStatePackageManifest {
    let data = try QixiStrictJSONDocumentValidator.validatedObjectData(
      from: packageURL.appendingPathComponent(manifestFilename, isDirectory: false),
      label: "Qixi MCTS state manifest",
      maxBytes: maxManifestBytes
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(QixiMCTSStatePackageManifest.self, from: data)
    guard (manifest.schemaVersion == 1 || manifest.schemaVersion == QixiMCTSStatePackageManifest.currentSchemaVersion),
          manifest.kind == QixiMCTSStatePackageManifest.kindValue else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state manifest",
        message: "has an unsupported schema"
      )
    }
    return manifest
  }

  private static func validatePackageURL(_ packageURL: URL) throws {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory)
    let values = try? packageURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "must not be a symbolic link"
      )
    }
    guard exists else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "path does not exist"
      )
    }
    // Directory packages (legacy) or already-materialized temp dirs.
    let looksLikeDirectory = isDirectory.boolValue || values?.isDirectory == true
    if looksLikeDirectory {
      let hasManifest = FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent(manifestFilename, isDirectory: false).path
      )
      guard hasManifest else {
        throw QixiStrictJSONError.malformed(
          label: "Qixi MCTS state package",
          message: "missing manifest.json"
        )
      }
      return
    }
    // Sealed image documents are validated during materializePackageDirectory.
  }

  private static func validateTombstoneURL(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isSymbolicLink != true, values.isRegularFile == true else {
      throw QixiStrictJSONError.notRegularFile(label: "Qixi native engine tombstone", path: url.path)
    }
    let byteCount = UInt64(max(0, values.fileSize ?? 0))
    guard byteCount > 0 && byteCount <= maxTombstoneBytes else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi native engine tombstone",
        message: "has an invalid byte count"
      )
    }
  }

  private static func validateCoreStateURL(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isSymbolicLink != true, values.isRegularFile == true else {
      throw QixiStrictJSONError.notRegularFile(label: "Qixi core MCTS state", path: url.path)
    }
    let byteCount = UInt64(max(0, values.fileSize ?? 0))
    guard byteCount > 0 && byteCount <= maxCoreStateBytes else {
      throw QixiStrictJSONError.malformed(
        label: "Qixi core MCTS state",
        message: "has an invalid byte count"
      )
    }
  }
}

enum QixiLifecycleTombstoneStore {
  static let tombstoneFilename = "lifecycle-tombstone.qixi-state.json"
  static let maxTombstoneBytes = 64 * 1024

  static var tombstoneURL: URL {
    QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(tombstoneFilename, isDirectory: false)
  }

  static func mark(
    snapshot: QixiAppSnapshot,
    reason: String,
    engineTombstoneFilename: String? = nil,
    markedAt: Date = Date()
  ) throws {
    let tombstone = QixiLifecycleTombstone(
      markedAt: markedAt,
      reason: reason,
      snapshotSavedAt: snapshot.savedAt,
      snapshotFilename: QixiSnapshotStore.snapshotFilename,
      selectedEngine: snapshot.selectedEngine,
      currentPly: snapshot.currentPly,
      mainLineCount: snapshot.mainLine.count,
      engineTombstoneFilename: engineTombstoneFilename
    )
    let directory = QixiSnapshotStore.snapshotsDirectory
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: directory,
      label: "Qixi lifecycle tombstone directory"
    )
    let data = try encode(tombstone)
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: tombstoneURL,
      label: "Qixi lifecycle tombstone path"
    )
  }

  static func load() -> QixiLifecycleTombstone? {
    do {
      return try decode(from: tombstoneURL)
    } catch {
      return nil
    }
  }

  static func encode(_ tombstone: QixiLifecycleTombstone) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(tombstone)
  }

  static func decode(_ data: Data) throws -> QixiLifecycleTombstone? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      data,
      label: "Qixi lifecycle tombstone",
      maxBytes: maxTombstoneBytes
    )
    return try decodeValidatedObjectData(objectData)
  }

  static func decode(from url: URL) throws -> QixiLifecycleTombstone? {
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      from: url,
      label: "Qixi lifecycle tombstone",
      maxBytes: maxTombstoneBytes
    )
    return try decodeValidatedObjectData(objectData)
  }

  private static func decodeValidatedObjectData(_ objectData: Data) throws -> QixiLifecycleTombstone? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let tombstone = try decoder.decode(QixiLifecycleTombstone.self, from: objectData)
    guard tombstone.schemaVersion == QixiLifecycleTombstone.currentSchemaVersion else { return nil }
    return tombstone
  }
}
