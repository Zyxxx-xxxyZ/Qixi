import CryptoKit
import Darwin
import Foundation

struct NativeKataGoModelIntegrityReport: Equatable {
  var resourceName: String
  var byteCount: UInt64
  var sha256HexDigest: String
}

struct NativeKataGoCoreMLPackageIntegrityReport: Equatable {
  var resourceName: String
  var fileCount: Int
  var totalByteCount: UInt64
  var sha256TreeDigest: String
}

enum QixiNativeModelIntegrityError: Error, Equatable, LocalizedError {
  case invalidChunkSize(Int)
  case missingFile(String)
  case symbolicLink(String)
  case notRegularFile(String)
  case unreadableAttributes(String)
  case byteCountMismatch(resourceName: String, expected: UInt64, actual: UInt64)
  case sha256Mismatch(resourceName: String, expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .invalidChunkSize(let size):
      return "Native model SHA-256 chunk size must be positive: \(size)"
    case .missingFile(let path):
      return "Native model file is missing: \(path)"
    case .symbolicLink(let path):
      return "Native model file must not be a symbolic link: \(path)"
    case .notRegularFile(let path):
      return "Native model path must be a regular file: \(path)"
    case .unreadableAttributes(let path):
      return "Native model file attributes are unreadable: \(path)"
    case .byteCountMismatch(let resourceName, let expected, let actual):
      return "Native model \(resourceName) byte count mismatch: expected \(expected), actual \(actual)"
    case .sha256Mismatch(let resourceName, let expected, let actual):
      return "Native model \(resourceName) SHA-256 mismatch: expected \(expected), actual \(actual)"
    }
  }
}

enum QixiNativeCoreMLPackageIntegrityError: Error, Equatable, LocalizedError {
  case invalidChunkSize(Int)
  case invalidRelativePath(String)
  case missingPackage(String)
  case packageNotDirectory(String)
  case emptyPackage(String)
  case unreadablePackage(String)
  case unsupportedPackageEntry(String)
  case fileCountMismatch(resourceName: String, expected: Int, actual: Int)
  case byteCountMismatch(resourceName: String, expected: UInt64, actual: UInt64)
  case sha256Mismatch(resourceName: String, expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .invalidChunkSize(let size):
      return "CoreML package SHA-256 chunk size must be positive: \(size)"
    case .invalidRelativePath(let path):
      return "CoreML package manifest path is not a safe relative path: \(path)"
    case .missingPackage(let path):
      return "CoreML package is missing: \(path)"
    case .packageNotDirectory(let path):
      return "CoreML package must be a directory: \(path)"
    case .emptyPackage(let path):
      return "CoreML package must contain at least one regular file: \(path)"
    case .unreadablePackage(let path):
      return "CoreML package is unreadable: \(path)"
    case .unsupportedPackageEntry(let path):
      return "CoreML package contains an unsupported entry: \(path)"
    case .fileCountMismatch(let resourceName, let expected, let actual):
      return "CoreML package \(resourceName) file count mismatch: expected \(expected), actual \(actual)"
    case .byteCountMismatch(let resourceName, let expected, let actual):
      return "CoreML package \(resourceName) byte count mismatch: expected \(expected), actual \(actual)"
    case .sha256Mismatch(let resourceName, let expected, let actual):
      return "CoreML package \(resourceName) SHA-256 tree digest mismatch: expected \(expected), actual \(actual)"
    }
  }
}

enum QixiNativeModelIntegrity {
  static let defaultHashChunkByteCount = 1024 * 1024

  static func byteCount(
    of url: URL,
    fileManager: FileManager = .default
  ) throws -> UInt64 {
    try validateRegularModelFile(at: url, fileManager: fileManager)
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    return try validateRegularOpenModelFile(handle, originalURL: url)
  }

  static func byteCountMatchesManifest(
    _ url: URL,
    spec: NativeKataGoModelSpec,
    fileManager: FileManager = .default
  ) -> Bool {
    (try? byteCount(of: url, fileManager: fileManager)) == spec.expectedByteCount
  }

  static func sha256HexDigest(
    of url: URL,
    chunkByteCount: Int = defaultHashChunkByteCount
  ) throws -> String {
    guard chunkByteCount > 0 else {
      throw QixiNativeModelIntegrityError.invalidChunkSize(chunkByteCount)
    }
    try validateRegularModelFile(at: url)
    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }
    let openedByteCount = try validateRegularOpenModelFile(handle, originalURL: url)

    var hasher = SHA256()
    var bytesRead: UInt64 = 0
    while true {
      let chunk = handle.readData(ofLength: chunkByteCount)
      if chunk.isEmpty {
        break
      }
      let nextBytesRead = bytesRead.addingReportingOverflow(UInt64(chunk.count))
      guard !nextBytesRead.overflow else {
        throw QixiNativeModelIntegrityError.byteCountMismatch(
          resourceName: url.lastPathComponent,
          expected: openedByteCount,
          actual: UInt64.max
        )
      }
      bytesRead = nextBytesRead.partialValue
      hasher.update(data: chunk)
    }
    guard bytesRead == openedByteCount else {
      throw QixiNativeModelIntegrityError.byteCountMismatch(
        resourceName: url.lastPathComponent,
        expected: openedByteCount,
        actual: bytesRead
      )
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func verifyModel(
    at url: URL,
    spec: NativeKataGoModelSpec,
    fileManager: FileManager = .default,
    chunkByteCount: Int = defaultHashChunkByteCount
  ) throws -> NativeKataGoModelIntegrityReport {
    let actualByteCount = try byteCount(of: url, fileManager: fileManager)
    guard actualByteCount == spec.expectedByteCount else {
      throw QixiNativeModelIntegrityError.byteCountMismatch(
        resourceName: spec.resourceName,
        expected: spec.expectedByteCount,
        actual: actualByteCount
      )
    }

    let actualDigest = try sha256HexDigest(of: url, chunkByteCount: chunkByteCount)
    guard actualDigest == spec.sha256HexDigest else {
      throw QixiNativeModelIntegrityError.sha256Mismatch(
        resourceName: spec.resourceName,
        expected: spec.sha256HexDigest,
        actual: actualDigest
      )
    }

    return NativeKataGoModelIntegrityReport(
      resourceName: spec.resourceName,
      byteCount: actualByteCount,
      sha256HexDigest: actualDigest
    )
  }

  private static func validateRegularModelFile(
    at url: URL,
    fileManager: FileManager = .default
  ) throws {
    if let symlinkPath = symbolicLinkComponentPath(in: url) {
      throw QixiNativeModelIntegrityError.symbolicLink(symlinkPath)
    }
    guard fileManager.fileExists(atPath: url.path) else {
      throw QixiNativeModelIntegrityError.missingFile(url.path)
    }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isSymbolicLink != true else {
      throw QixiNativeModelIntegrityError.symbolicLink(url.path)
    }
    guard values?.isRegularFile == true else {
      throw QixiNativeModelIntegrityError.notRegularFile(url.path)
    }
  }

  fileprivate static func symbolicLinkComponentPath(in url: URL) -> String? {
    let components = url.standardizedFileURL.pathComponents
    guard !components.isEmpty else { return nil }
    var currentPath = components[0]
    for component in components.dropFirst() {
      currentPath = (currentPath as NSString).appendingPathComponent(component)
      let currentURL = URL(fileURLWithPath: currentPath)
      let values = try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true,
         !isAllowedPlatformSymlinkAlias(currentURL) {
        return currentURL.path
      }
    }
    return nil
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

  @discardableResult
  private static func validateRegularOpenModelFile(
    _ handle: FileHandle,
    originalURL url: URL
  ) throws -> UInt64 {
    var statBuffer = stat()
    guard fstat(handle.fileDescriptor, &statBuffer) == 0 else {
      throw QixiNativeModelIntegrityError.unreadableAttributes(url.path)
    }
    guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
      throw QixiNativeModelIntegrityError.notRegularFile(url.path)
    }
    guard statBuffer.st_size >= 0 else {
      throw QixiNativeModelIntegrityError.unreadableAttributes(url.path)
    }
    return UInt64(statBuffer.st_size)
  }
}

enum QixiNativeCoreMLPackageIntegrity {
  static let defaultHashChunkByteCount = QixiNativeModelIntegrity.defaultHashChunkByteCount
  private static let digestDomain = "QIXI_COREML_PACKAGE_TREE_V1\n"

  static func quickPackageMatchesManifest(
    _ url: URL,
    packageSpec: NativeKataGoCoreMLPackageSpec,
    fileManager: FileManager = .default
  ) -> Bool {
    guard let report = try? packageFootprint(
      at: url,
      fileManager: fileManager,
      maxFileCount: packageSpec.expectedFileCount,
      maxTotalByteCount: packageSpec.expectedTotalByteCount,
      budgetResourceName: packageSpec.resourceName
    ) else {
      return false
    }
    return report.fileCount == packageSpec.expectedFileCount &&
      report.totalByteCount == packageSpec.expectedTotalByteCount
  }

  static func verifyPackage(
    at url: URL,
    packageSpec: NativeKataGoCoreMLPackageSpec,
    fileManager: FileManager = .default,
    chunkByteCount: Int = defaultHashChunkByteCount
  ) throws -> NativeKataGoCoreMLPackageIntegrityReport {
    guard chunkByteCount > 0 else {
      throw QixiNativeCoreMLPackageIntegrityError.invalidChunkSize(chunkByteCount)
    }
    let report = try packageFootprint(
      at: url,
      fileManager: fileManager,
      includeTreeDigest: true,
      chunkByteCount: chunkByteCount,
      maxFileCount: packageSpec.expectedFileCount,
      maxTotalByteCount: packageSpec.expectedTotalByteCount,
      budgetResourceName: packageSpec.resourceName
    )
    guard report.fileCount == packageSpec.expectedFileCount else {
      throw QixiNativeCoreMLPackageIntegrityError.fileCountMismatch(
        resourceName: packageSpec.resourceName,
        expected: packageSpec.expectedFileCount,
        actual: report.fileCount
      )
    }
    guard report.totalByteCount == packageSpec.expectedTotalByteCount else {
      throw QixiNativeCoreMLPackageIntegrityError.byteCountMismatch(
        resourceName: packageSpec.resourceName,
        expected: packageSpec.expectedTotalByteCount,
        actual: report.totalByteCount
      )
    }
    guard report.sha256TreeDigest == packageSpec.sha256TreeDigest else {
      throw QixiNativeCoreMLPackageIntegrityError.sha256Mismatch(
        resourceName: packageSpec.resourceName,
        expected: packageSpec.sha256TreeDigest,
        actual: report.sha256TreeDigest
      )
    }
    return NativeKataGoCoreMLPackageIntegrityReport(
      resourceName: packageSpec.resourceName,
      fileCount: report.fileCount,
      totalByteCount: report.totalByteCount,
      sha256TreeDigest: report.sha256TreeDigest
    )
  }

  static func packageTreeDigest(
    at url: URL,
    fileManager: FileManager = .default,
    chunkByteCount: Int = defaultHashChunkByteCount
  ) throws -> NativeKataGoCoreMLPackageIntegrityReport {
    guard chunkByteCount > 0 else {
      throw QixiNativeCoreMLPackageIntegrityError.invalidChunkSize(chunkByteCount)
    }
    return try packageFootprint(
      at: url,
      fileManager: fileManager,
      includeTreeDigest: true,
      chunkByteCount: chunkByteCount
    )
  }

  private static func packageFootprint(
    at url: URL,
    fileManager: FileManager,
    includeTreeDigest: Bool = false,
    chunkByteCount: Int = defaultHashChunkByteCount,
    maxFileCount: Int? = nil,
    maxTotalByteCount: UInt64? = nil,
    budgetResourceName: String? = nil
  ) throws -> NativeKataGoCoreMLPackageIntegrityReport {
    if let symlinkPath = QixiNativeModelIntegrity.symbolicLinkComponentPath(in: url) {
      throw QixiNativeCoreMLPackageIntegrityError.packageNotDirectory(symlinkPath)
    }
    guard fileManager.fileExists(atPath: url.path) else {
      throw QixiNativeCoreMLPackageIntegrityError.missingPackage(url.path)
    }
    let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true && rootValues.isSymbolicLink != true else {
      throw QixiNativeCoreMLPackageIntegrityError.packageNotDirectory(url.path)
    }
    guard let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
      options: []
    ) else {
      throw QixiNativeCoreMLPackageIntegrityError.unreadablePackage(url.path)
    }

    var files: [(relativePath: String, url: URL, byteCount: UInt64)] = []
    var fileCount = 0
    var totalByteCount: UInt64 = 0
    let resourceName = budgetResourceName ?? url.lastPathComponent
    for case let child as URL in enumerator {
      let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
      if values.isSymbolicLink == true {
        throw QixiNativeCoreMLPackageIntegrityError.unsupportedPackageEntry(child.path)
      }
      if values.isDirectory == true {
        continue
      }
      guard values.isRegularFile == true else {
        throw QixiNativeCoreMLPackageIntegrityError.unsupportedPackageEntry(child.path)
      }
      let relativePath = try safeRelativePath(of: child, under: url)
      fileCount += 1
      if let maxFileCount, fileCount > maxFileCount {
        throw QixiNativeCoreMLPackageIntegrityError.fileCountMismatch(
          resourceName: resourceName,
          expected: maxFileCount,
          actual: fileCount
        )
      }
      let byteCount = UInt64(values.fileSize ?? 0)
      let added = totalByteCount.addingReportingOverflow(byteCount)
      if added.overflow {
        throw QixiNativeCoreMLPackageIntegrityError.byteCountMismatch(
          resourceName: resourceName,
          expected: maxTotalByteCount ?? UInt64.max,
          actual: UInt64.max
        )
      }
      totalByteCount = added.partialValue
      if let maxTotalByteCount, totalByteCount > maxTotalByteCount {
        throw QixiNativeCoreMLPackageIntegrityError.byteCountMismatch(
          resourceName: resourceName,
          expected: maxTotalByteCount,
          actual: totalByteCount
        )
      }
      if includeTreeDigest {
        files.append((relativePath, child, byteCount))
      }
    }
    guard fileCount > 0 else {
      throw QixiNativeCoreMLPackageIntegrityError.emptyPackage(url.path)
    }
    let digest: String
    if includeTreeDigest {
      files.sort { $0.relativePath < $1.relativePath }
      digest = try digestFiles(files, packageResourceName: resourceName, chunkByteCount: chunkByteCount)
    } else {
      digest = ""
    }
    return NativeKataGoCoreMLPackageIntegrityReport(
      resourceName: url.lastPathComponent,
      fileCount: fileCount,
      totalByteCount: totalByteCount,
      sha256TreeDigest: digest
    )
  }

  private static func digestFiles(
    _ files: [(relativePath: String, url: URL, byteCount: UInt64)],
    packageResourceName: String,
    chunkByteCount: Int
  ) throws -> String {
    var hasher = SHA256()
    hasher.update(data: Data(digestDomain.utf8))
    for file in files {
      hasher.update(data: Data("\(file.relativePath.utf8.count):".utf8))
      hasher.update(data: Data(file.relativePath.utf8))
      hasher.update(data: Data(":\(file.byteCount)\n".utf8))
      let handle = try FileHandle(forReadingFrom: file.url)
      defer {
        try? handle.close()
      }
      let openedByteCount = try validateRegularOpenPackageFile(
        handle,
        fileURL: file.url,
        expectedByteCount: file.byteCount,
        packageResourceName: packageResourceName
      )
      var bytesRead: UInt64 = 0
      while true {
        let chunk = handle.readData(ofLength: chunkByteCount)
        if chunk.isEmpty {
          break
        }
        let nextBytesRead = bytesRead.addingReportingOverflow(UInt64(chunk.count))
        guard !nextBytesRead.overflow else {
          throw QixiNativeCoreMLPackageIntegrityError.byteCountMismatch(
            resourceName: packageResourceName,
            expected: openedByteCount,
            actual: UInt64.max
          )
        }
        bytesRead = nextBytesRead.partialValue
        hasher.update(data: chunk)
      }
      guard bytesRead == openedByteCount else {
        throw QixiNativeCoreMLPackageIntegrityError.byteCountMismatch(
          resourceName: packageResourceName,
          expected: openedByteCount,
          actual: bytesRead
        )
      }
      hasher.update(data: Data("\n".utf8))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func validateRegularOpenPackageFile(
    _ handle: FileHandle,
    fileURL: URL,
    expectedByteCount: UInt64,
    packageResourceName: String
  ) throws -> UInt64 {
    var statBuffer = stat()
    guard fstat(handle.fileDescriptor, &statBuffer) == 0 else {
      throw QixiNativeCoreMLPackageIntegrityError.unreadablePackage(fileURL.path)
    }
    guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
      throw QixiNativeCoreMLPackageIntegrityError.unsupportedPackageEntry(fileURL.path)
    }
    guard statBuffer.st_size >= 0 else {
      throw QixiNativeCoreMLPackageIntegrityError.unreadablePackage(fileURL.path)
    }
    let openedByteCount = UInt64(statBuffer.st_size)
    guard openedByteCount == expectedByteCount else {
      throw QixiNativeCoreMLPackageIntegrityError.byteCountMismatch(
        resourceName: packageResourceName,
        expected: expectedByteCount,
        actual: openedByteCount
      )
    }
    return openedByteCount
  }

  private static func safeRelativePath(of child: URL, under root: URL) throws -> String {
    let rootPath = root.standardizedFileURL.path
    let childPath = child.standardizedFileURL.path
    guard childPath.hasPrefix(rootPath + "/") else {
      throw QixiNativeCoreMLPackageIntegrityError.unsupportedPackageEntry(child.path)
    }
    let relativePath = String(childPath.dropFirst(rootPath.count + 1))
    guard !relativePath.isEmpty && !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw QixiNativeCoreMLPackageIntegrityError.invalidRelativePath(relativePath)
    }
    return relativePath
  }
}
