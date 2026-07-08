import Darwin
import Foundation

struct NativeKataGoModelInstallReceipt: Codable, Equatable {
  var schemaVersion: Int
  var engine: String
  var resourceName: String
  var expectedByteCount: UInt64
  var sha256HexDigest: String
  var installedByteCount: UInt64
  var installedModificationTimeSince1970: TimeInterval
  var installedDeviceID: Int64
  var installedFileID: Int64
}

struct NativeKataGoCoreMLPackageInstallReceipt: Codable, Equatable {
  var schemaVersion: Int
  var resourceName: String
  var variantID: String
  var expectedFileCount: Int
  var expectedTotalByteCount: UInt64
  var sha256TreeDigest: String
  var installedFileCount: Int
  var installedTotalByteCount: UInt64
}

enum QixiNativeModelInstallReceiptStore {
  static let schemaVersion = 3
  static let maxReceiptBytes: UInt64 = 64 * 1024

  static func receiptURL(forModelAt modelURL: URL) -> URL {
    modelURL
      .deletingLastPathComponent()
      .appendingPathComponent(".\(modelURL.lastPathComponent).qixi-model-receipt.json")
  }

  static func receipt(
    forModelAt modelURL: URL,
    spec: NativeKataGoModelSpec,
    fileManager: FileManager = .default
  ) throws -> NativeKataGoModelInstallReceipt {
    _ = fileManager
    let statBuffer = try openedRegularModelStat(at: modelURL)
    return NativeKataGoModelInstallReceipt(
      schemaVersion: schemaVersion,
      engine: spec.engine.rawValue,
      resourceName: spec.resourceName,
      expectedByteCount: spec.expectedByteCount,
      sha256HexDigest: spec.sha256HexDigest,
      installedByteCount: UInt64(statBuffer.st_size),
      installedModificationTimeSince1970: timeIntervalSince1970(statBuffer.st_mtimespec),
      installedDeviceID: Int64(statBuffer.st_dev),
      installedFileID: Int64(statBuffer.st_ino)
    )
  }

  static func writeReceipt(
    forModelAt modelURL: URL,
    spec: NativeKataGoModelSpec,
    fileManager: FileManager = .default
  ) throws {
    let receiptURL = receiptURL(forModelAt: modelURL)
    let data = try JSONEncoder.qixiModelReceiptEncoder.encode(
      receipt(forModelAt: modelURL, spec: spec, fileManager: fileManager)
    )
    let receiptDirectory = receiptURL.deletingLastPathComponent()
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: receiptDirectory,
      label: "Qixi native model install receipt directory",
      fileManager: fileManager
    )
    markExcludedFromBackup(receiptDirectory)
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(
      in: receiptURL,
      label: "Qixi native model install receipt path"
    )
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: receiptURL,
      label: "Qixi native model install receipt path",
      fileProtection: nil
    )
    markExcludedFromBackup(receiptURL)
  }

  static func readReceipt(
    forModelAt modelURL: URL,
    fileManager: FileManager = .default
  ) throws -> NativeKataGoModelInstallReceipt {
    let receiptURL = receiptURL(forModelAt: modelURL)
    let data = try QixiNativeModelInstallReceiptJSON.validatedObjectData(
      from: receiptURL,
      label: "Qixi native model install receipt",
      maxBytes: maxReceiptBytes,
      fileManager: fileManager
    )
    return try JSONDecoder().decode(NativeKataGoModelInstallReceipt.self, from: data)
  }

  static func receiptMatchesManifest(
    forModelAt modelURL: URL,
    spec: NativeKataGoModelSpec,
    fileManager: FileManager = .default
  ) -> Bool {
    guard let existing = try? readReceipt(forModelAt: modelURL, fileManager: fileManager) else {
      return false
    }
    guard let expected = try? receipt(forModelAt: modelURL, spec: spec, fileManager: fileManager) else {
      return false
    }
    return existing == expected
  }

  private static func markExcludedFromBackup(_ url: URL) {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? mutableURL.setResourceValues(values)
  }

  private static func openedRegularModelStat(at modelURL: URL) throws -> stat {
    let handle = try FileHandle(forReadingFrom: modelURL)
    defer { try? handle.close() }
    var statBuffer = stat()
    guard fstat(handle.fileDescriptor, &statBuffer) == 0 else {
      throw CocoaError(.fileReadUnknown)
    }
    guard (statBuffer.st_mode & S_IFMT) == S_IFREG, statBuffer.st_size >= 0 else {
      throw CocoaError(.fileReadUnknown)
    }
    return statBuffer
  }

  private static func timeIntervalSince1970(_ timeSpec: timespec) -> TimeInterval {
    TimeInterval(timeSpec.tv_sec) + TimeInterval(timeSpec.tv_nsec) / 1_000_000_000
  }
}

enum QixiNativeCoreMLPackageInstallReceiptStore {
  static let schemaVersion = 1
  static let maxReceiptBytes: UInt64 = 64 * 1024

  static func receiptURL(forPackageAt packageURL: URL) -> URL {
    packageURL
      .deletingLastPathComponent()
      .appendingPathComponent(".\(packageURL.lastPathComponent).qixi-coreml-package-receipt.json")
  }

  static func receipt(
    forPackageAt packageURL: URL,
    packageSpec: NativeKataGoCoreMLPackageSpec,
    fileManager: FileManager = .default,
    chunkByteCount: Int = QixiNativeCoreMLPackageIntegrity.defaultHashChunkByteCount
  ) throws -> NativeKataGoCoreMLPackageInstallReceipt {
    let report = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
      at: packageURL,
      packageSpec: packageSpec,
      fileManager: fileManager,
      chunkByteCount: chunkByteCount
    )
    return NativeKataGoCoreMLPackageInstallReceipt(
      schemaVersion: schemaVersion,
      resourceName: packageSpec.resourceName,
      variantID: packageSpec.variantID,
      expectedFileCount: packageSpec.expectedFileCount,
      expectedTotalByteCount: packageSpec.expectedTotalByteCount,
      sha256TreeDigest: packageSpec.sha256TreeDigest,
      installedFileCount: report.fileCount,
      installedTotalByteCount: report.totalByteCount
    )
  }

  static func writeReceipt(
    forPackageAt packageURL: URL,
    packageSpec: NativeKataGoCoreMLPackageSpec,
    fileManager: FileManager = .default,
    chunkByteCount: Int = QixiNativeCoreMLPackageIntegrity.defaultHashChunkByteCount
  ) throws {
    let receiptURL = receiptURL(forPackageAt: packageURL)
    let data = try JSONEncoder.qixiModelReceiptEncoder.encode(
      receipt(
        forPackageAt: packageURL,
        packageSpec: packageSpec,
        fileManager: fileManager,
        chunkByteCount: chunkByteCount
      )
    )
    let receiptDirectory = receiptURL.deletingLastPathComponent()
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: receiptDirectory,
      label: "Qixi native CoreML package install receipt directory",
      fileManager: fileManager
    )
    markExcludedFromBackup(receiptDirectory)
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(
      in: receiptURL,
      label: "Qixi native CoreML package install receipt path"
    )
    try QixiTrustedFilePath.writeProtectedDataAtomically(
      data,
      to: receiptURL,
      label: "Qixi native CoreML package install receipt path",
      fileProtection: nil
    )
    markExcludedFromBackup(receiptURL)
  }

  static func readReceipt(
    forPackageAt packageURL: URL,
    fileManager: FileManager = .default
  ) throws -> NativeKataGoCoreMLPackageInstallReceipt {
    let receiptURL = receiptURL(forPackageAt: packageURL)
    let data = try QixiNativeModelInstallReceiptJSON.validatedObjectData(
      from: receiptURL,
      label: "Qixi native CoreML package install receipt",
      maxBytes: maxReceiptBytes,
      fileManager: fileManager
    )
    return try JSONDecoder().decode(NativeKataGoCoreMLPackageInstallReceipt.self, from: data)
  }

  static func receiptMatchesManifest(
    forPackageAt packageURL: URL,
    packageSpec: NativeKataGoCoreMLPackageSpec,
    fileManager: FileManager = .default
  ) -> Bool {
    guard let existing = try? readReceipt(forPackageAt: packageURL, fileManager: fileManager) else {
      return false
    }
    guard let expected = try? receipt(forPackageAt: packageURL, packageSpec: packageSpec, fileManager: fileManager) else {
      return false
    }
    return existing == expected
  }

  private static func markExcludedFromBackup(_ url: URL) {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? mutableURL.setResourceValues(values)
  }
}

private extension JSONEncoder {
  static var qixiModelReceiptEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

private enum QixiNativeModelInstallReceiptJSONError: Error, Equatable, LocalizedError {
  case documentTooLarge(label: String, bytes: UInt64, limit: UInt64)
  case malformed(label: String, message: String)
  case notRegularFile(label: String, path: String)
  case duplicateKey(label: String, key: String)
  case nonStandardConstant(label: String, value: String)

  var errorDescription: String? {
    switch self {
    case .documentTooLarge(let label, let bytes, let limit):
      return "\(label) has \(bytes) bytes, exceeding the \(limit) byte limit."
    case .malformed(let label, let message):
      return "\(label) \(message)."
    case .notRegularFile(let label, let path):
      return "\(label) must be a regular file before loading: \(path)"
    case .duplicateKey(let label, let key):
      return "\(label) must not contain duplicate JSON key '\(key)'."
    case .nonStandardConstant(let label, let value):
      return "\(label) must not contain non-standard JSON constant \(value)."
    }
  }
}

private enum QixiNativeModelInstallReceiptJSON {
  static func validatedObjectData(
    from url: URL,
    label: String,
    maxBytes: UInt64,
    fileManager: FileManager
  ) throws -> Data {
    let data = try boundedData(
      from: url,
      label: label,
      maxBytes: maxBytes,
      fileManager: fileManager
    )
    try Scanner(data: data, label: label).validateTopLevelObject()
    return data
  }

  private static func boundedData(
    from url: URL,
    label: String,
    maxBytes: UInt64,
    fileManager: FileManager
  ) throws -> Data {
    try rejectSymbolicLinkComponents(in: url, label: label)
    try validateRegularReceiptFileURL(url, label: label, fileManager: fileManager)
    if let byteCount = try receiptByteCount(at: url, fileManager: fileManager),
       byteCount > maxBytes {
      throw QixiNativeModelInstallReceiptJSONError.documentTooLarge(
        label: label,
        bytes: byteCount,
        limit: maxBytes
      )
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try validateRegularOpenReceiptFile(handle, originalURL: url, label: label)
    let readLimit = maxBytes >= UInt64(Int.max) ? Int.max : Int(maxBytes + 1)
    let data = handle.readData(ofLength: readLimit)
    guard UInt64(data.count) <= maxBytes else {
      throw QixiNativeModelInstallReceiptJSONError.documentTooLarge(
        label: label,
        bytes: UInt64(data.count),
        limit: maxBytes
      )
    }
    return data
  }

  private static func validateRegularReceiptFileURL(
    _ url: URL,
    label: String,
    fileManager: FileManager
  ) throws {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw QixiNativeModelInstallReceiptJSONError.malformed(
          label: label,
          message: "path must not contain symbolic links: \(url.path)"
        )
      }
      guard values.isRegularFile == true, values.isDirectory != true else {
        throw QixiNativeModelInstallReceiptJSONError.notRegularFile(label: label, path: url.path)
      }
    } catch let error as QixiNativeModelInstallReceiptJSONError {
      throw error
    } catch {
      guard fileManager.fileExists(atPath: url.path) else { return }
      throw QixiNativeModelInstallReceiptJSONError.malformed(
        label: label,
        message: "file type could not be inspected before loading: \(url.path)"
      )
    }
  }

  private static func validateRegularOpenReceiptFile(
    _ handle: FileHandle,
    originalURL url: URL,
    label: String
  ) throws {
    var statBuffer = stat()
    guard fstat(handle.fileDescriptor, &statBuffer) == 0 else {
      throw QixiNativeModelInstallReceiptJSONError.malformed(
        label: label,
        message: "open file type could not be inspected before loading: \(url.path)"
      )
    }
    guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
      throw QixiNativeModelInstallReceiptJSONError.notRegularFile(label: label, path: url.path)
    }
  }

  private static func receiptByteCount(at url: URL, fileManager: FileManager) throws -> UInt64? {
    do {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      if let size = attributes[.size] as? NSNumber {
        return size.uint64Value
      }
    } catch {
      return nil
    }
    return nil
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
        throw QixiNativeModelInstallReceiptJSONError.malformed(
          label: label,
          message: "path must not contain symbolic links: \(currentURL.path)"
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
          throw QixiNativeModelInstallReceiptJSONError.duplicateKey(label: label, key: key)
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

    private func malformed(_ message: String) -> QixiNativeModelInstallReceiptJSONError {
      QixiNativeModelInstallReceiptJSONError.malformed(label: label, message: message)
    }

    private func nonStandardConstant(_ value: String) -> QixiNativeModelInstallReceiptJSONError {
      QixiNativeModelInstallReceiptJSONError.nonStandardConstant(label: label, value: value)
    }
  }
}
