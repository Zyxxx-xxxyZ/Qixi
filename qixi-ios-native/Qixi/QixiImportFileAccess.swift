import Foundation
import UIKit

enum QixiImportedFileAccess {
  enum AccessError: Error, LocalizedError {
    case coordinationFailed
    case packageIncomplete(String)
    case downloadTimedOut(String)
    case notReadable(String)

    var errorDescription: String? {
      switch self {
      case .coordinationFailed:
        return "Could not coordinate reading the selected file."
      case .packageIncomplete(let detail):
        return "Search-state package is incomplete: \(detail)"
      case .downloadTimedOut(let path):
        return "Timed out downloading from iCloud: \(path)"
      case .notReadable(let path):
        return "Could not read selected item: \(path)"
      }
    }
  }

  /// Copy a user-picked item into a private temp location for safe parsing.
  /// Resolves `.qixi-mcts` package roots, waits for iCloud download, and preserves
  /// package directories (not flattened into a single file).
  static func makeTemporaryLocalCopy(from pickedURL: URL) throws -> URL {
    let scoped = pickedURL.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        pickedURL.stopAccessingSecurityScopedResource()
      }
    }

    let resolvedURL = resolveMCTSPackageRootIfNeeded(pickedURL)
    try waitForUbiquitousItemIfNeeded(at: resolvedURL)

    var coordinatedResult: Result<URL, Error>?
    var coordinationError: NSError?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    // For packages, request the full item tree.
    let options: NSFileCoordinator.ReadingOptions = []
    coordinator.coordinate(readingItemAt: resolvedURL, options: options, error: &coordinationError) { readableURL in
      coordinatedResult = Result {
        try copyItemPreservingPackage(from: readableURL)
      }
    }

    if let coordinatedResult {
      let copy = try coordinatedResult.get()
      try validateCopiedPackageIfNeeded(copy, original: resolvedURL)
      return copy
    }
    throw coordinationError ?? AccessError.coordinationFailed
  }

  static func removeTemporaryCopy(_ url: URL?) {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }

  /// True if URL is (or is inside) a Qixi MCTS package / sealed image document.
  static func isMCTSPackageURL(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    if QixiMCTSStatePackageStore.filenameLooksLikePackage(name) {
      return true
    }
    // Sealed board document: PNG leading bytes + QIXIMC01 trailer (even if named .png).
    if looksLikeSealedImageDocument(url) {
      return true
    }
    let manifest = url.appendingPathComponent(QixiMCTSStatePackageStore.manifestFilename, isDirectory: false)
    return FileManager.default.fileExists(atPath: manifest.path)
  }

  /// Walk up a few parents to find a package root (user may open an inner file of a legacy dir package).
  static func resolveMCTSPackageRootIfNeeded(_ url: URL) -> URL {
    if isMCTSPackageURL(url) {
      return url
    }
    var current = url
    for _ in 0..<5 {
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      if isMCTSPackageURL(parent) {
        return parent
      }
      current = parent
    }
    return url
  }

  private static func looksLikeSealedImageDocument(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
    else { return false }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          data.count > 32,
          data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])),
          data.range(of: QixiMCTSStatePackageStore.imageDocumentMagic) != nil
    else { return false }
    return true
  }

  // MARK: - Private

  private static func copyItemPreservingPackage(from readableURL: URL) throws -> URL {
    let isDir = isDirectory(readableURL)
    let temporaryURL = temporaryCopyURL(for: readableURL, isDirectory: isDir)
    if FileManager.default.fileExists(atPath: temporaryURL.path) {
      try FileManager.default.removeItem(at: temporaryURL)
    }
    try FileManager.default.copyItem(at: readableURL, to: temporaryURL)
    return temporaryURL
  }

  private static func validateCopiedPackageIfNeeded(_ copyURL: URL, original: URL) throws {
    guard isMCTSPackageURL(original) || isMCTSPackageURL(copyURL) else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: copyURL.path, isDirectory: &isDirectory) else {
      throw AccessError.packageIncomplete("copied item missing")
    }
    // Sealed image documents (PNG + payload) are regular files.
    if !isDirectory.boolValue {
      guard looksLikeSealedImageDocument(copyURL) else {
        throw AccessError.packageIncomplete("copied file is not a sealed Qixi image document")
      }
      return
    }
    let manifest = copyURL.appendingPathComponent(
      QixiMCTSStatePackageStore.manifestFilename,
      isDirectory: false
    )
    guard FileManager.default.fileExists(atPath: manifest.path) else {
      throw AccessError.packageIncomplete("missing manifest.json (iCloud download incomplete?)")
    }
    // If the original package advertised a core state file, ensure it arrived with bytes.
    if let data = try? Data(contentsOf: manifest),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let coreName = obj["coreStateFilename"] as? String,
       !coreName.isEmpty {
      let coreURL = copyURL.appendingPathComponent(coreName, isDirectory: false)
      let attrs = try? FileManager.default.attributesOfItem(atPath: coreURL.path)
      let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
      guard FileManager.default.fileExists(atPath: coreURL.path), size > 0 else {
        throw AccessError.packageIncomplete("missing or empty \(coreName)")
      }
    }
  }

  private static func waitForUbiquitousItemIfNeeded(at url: URL, timeout: TimeInterval = 90) throws {
    let keys: Set<URLResourceKey> = [
      .isUbiquitousItemKey,
      .ubiquitousItemDownloadingStatusKey,
      .ubiquitousItemIsDownloadingKey,
      .ubiquitousItemDownloadingErrorKey
    ]
    let values = try? url.resourceValues(forKeys: keys)
    guard values?.isUbiquitousItem == true else { return }

    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    // Also kick the package children when the root is a directory package.
    if isDirectory(url) {
      if let children = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      ) {
        for child in children {
          try? FileManager.default.startDownloadingUbiquitousItem(at: child)
        }
      }
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let statusValues = try? url.resourceValues(forKeys: keys)
      if let error = statusValues?.ubiquitousItemDownloadingError {
        throw error
      }
      let status = statusValues?.ubiquitousItemDownloadingStatus
      let downloading = statusValues?.ubiquitousItemIsDownloading ?? false
      if status == .current || (status == nil && !downloading) {
        // For packages, require manifest to be present before returning.
        if isMCTSPackageURL(url) {
          let manifest = url.appendingPathComponent(
            QixiMCTSStatePackageStore.manifestFilename,
            isDirectory: false
          )
          if FileManager.default.fileExists(atPath: manifest.path) {
            return
          }
        } else {
          return
        }
      }
      if status == URLUbiquitousItemDownloadingStatus.notDownloaded || status == .downloaded {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    throw AccessError.downloadTimedOut(url.lastPathComponent)
  }

  private static func temporaryCopyURL(for readableURL: URL, isDirectory: Bool) -> URL {
    let filename = readableURL.lastPathComponent.isEmpty ? "imported-file" : readableURL.lastPathComponent
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("qixi-import-\(UUID().uuidString)-\(filename)", isDirectory: isDirectory)
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
      return isDir.boolValue
    }
    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
