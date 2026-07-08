import Foundation

struct NativeKataGoInstalledModel: Equatable {
  var resolvedModel: NativeKataGoResolvedModel
  var integrityReport: NativeKataGoModelIntegrityReport
}

struct NativeKataGoInstalledCoreMLPackage: Equatable {
  var modelSpec: NativeKataGoModelSpec
  var packageSpec: NativeKataGoCoreMLPackageSpec
  var packageURL: URL
  var integrityReport: NativeKataGoCoreMLPackageIntegrityReport
}

enum QixiNativeModelInstallerError: Error, Equatable, LocalizedError {
  case modelsDirectoryUnavailable
  case unrecognizedModel(String)
  case unrecognizedCoreMLPackage(String)

  var errorDescription: String? {
    switch self {
    case .modelsDirectoryUnavailable:
      return "Native model install directory is unavailable."
    case .unrecognizedModel(let fileName):
      return "Native model file is not recognized by the Qixi model manifest: \(fileName)"
    case .unrecognizedCoreMLPackage(let fileName):
      return "Native CoreML package is not recognized by the Qixi model manifest: \(fileName)"
    }
  }
}

enum QixiNativeModelInstallArtifactCleaner {
  static func cleanupOrphanedArtifacts(
    in directory: URL,
    fileManager: FileManager = .default,
    excluding protectedURLs: [URL] = []
  ) {
    let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
    guard let children = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants]
    ) else { return }
    for url in children where isRemovableInstallerArtifact(url) && !protectedPaths.contains(url.standardizedFileURL.path) {
      try? fileManager.removeItem(at: url)
    }
  }

  private static func isRemovableInstallerArtifact(_ url: URL) -> Bool {
    guard isInstallerArtifact(url) else { return false }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values?.isRegularFile == true && values?.isSymbolicLink != true
  }

  private static func isInstallerArtifact(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name.hasPrefix(".") &&
      (name.hasSuffix(".tmp") || name.hasSuffix(".backup") || name.hasSuffix(".receipt-backup"))
  }

  static func cleanupOrphanedCoreMLPackageArtifacts(
    in directory: URL,
    fileManager: FileManager = .default,
    excluding protectedURLs: [URL] = []
  ) {
    let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
    guard let children = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    ) else { return }
    for url in children where isRemovableCoreMLPackageArtifact(url) && !protectedPaths.contains(url.standardizedFileURL.path) {
      try? fileManager.removeItem(at: url)
    }
  }

  private static func isRemovableCoreMLPackageArtifact(_ url: URL) -> Bool {
    guard isCoreMLPackageInstallerArtifact(url) else { return false }
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isSymbolicLink != true else { return false }
    return values?.isDirectory == true || values?.isRegularFile == true
  }

  private static func isCoreMLPackageInstallerArtifact(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name.hasPrefix(".") &&
      (
        name.hasSuffix(".coreml-package-tmp") ||
        name.hasSuffix(".coreml-package-backup") ||
        name.hasSuffix(".coreml-package-receipt-backup")
      )
  }
}

struct QixiNativeModelInstaller {
  var fileManager: FileManager
  var modelsDirectory: URL

  init(
    fileManager: FileManager = .default,
    modelsDirectory: URL? = nil
  ) throws {
    guard let resolvedDirectory = modelsDirectory
      ?? QixiNativeModelStore.applicationSupportModelsDirectory(fileManager: fileManager) else {
      throw QixiNativeModelInstallerError.modelsDirectoryUnavailable
    }
    self.fileManager = fileManager
    self.modelsDirectory = resolvedDirectory
  }

  func installVerifiedModel(
    from sourceURL: URL,
    spec: NativeKataGoModelSpec,
    chunkByteCount: Int = QixiNativeModelIntegrity.defaultHashChunkByteCount
  ) throws -> NativeKataGoInstalledModel {
    _ = try QixiNativeModelIntegrity.verifyModel(
      at: sourceURL,
      spec: spec,
      fileManager: fileManager,
      chunkByteCount: chunkByteCount
    )

    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: modelsDirectory,
      label: "Qixi native model install directory",
      fileManager: fileManager
    )
    markExcludedFromBackup(modelsDirectory)
    QixiNativeModelInstallArtifactCleaner.cleanupOrphanedArtifacts(
      in: modelsDirectory,
      fileManager: fileManager,
      excluding: [sourceURL]
    )

    let destinationURL = modelsDirectory.appendingPathComponent(spec.resourceName)
    let temporaryURL = modelsDirectory.appendingPathComponent(".\(spec.resourceName).\(UUID().uuidString).tmp")
    let backupURL = modelsDirectory.appendingPathComponent(".\(spec.resourceName).\(UUID().uuidString).backup")
    let receiptURL = QixiNativeModelInstallReceiptStore.receiptURL(forModelAt: destinationURL)
    let receiptBackupURL = modelsDirectory.appendingPathComponent(".\(spec.resourceName).\(UUID().uuidString).receipt-backup")
    if fileManager.fileExists(atPath: temporaryURL.path) {
      try fileManager.removeItem(at: temporaryURL)
    }
    defer {
      if fileManager.fileExists(atPath: temporaryURL.path) {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    try fileManager.copyItem(at: sourceURL, to: temporaryURL)
    markExcludedFromBackup(temporaryURL)
    let copiedReport = try QixiNativeModelIntegrity.verifyModel(
      at: temporaryURL,
      spec: spec,
      fileManager: fileManager,
      chunkByteCount: chunkByteCount
    )

    let isReplacingExistingModel = fileManager.fileExists(atPath: destinationURL.path)
    var didMoveReceiptToBackup = false
    var didStartWritingNewReceipt = false
    let restoreBackups = {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.removeItem(at: destinationURL)
      }
      if fileManager.fileExists(atPath: backupURL.path) {
        try? fileManager.moveItem(at: backupURL, to: destinationURL)
        markExcludedFromBackup(destinationURL)
      }
      if didStartWritingNewReceipt && fileManager.fileExists(atPath: receiptURL.path) {
        try? fileManager.removeItem(at: receiptURL)
      }
      if didMoveReceiptToBackup && fileManager.fileExists(atPath: receiptBackupURL.path) {
        try? fileManager.moveItem(at: receiptBackupURL, to: receiptURL)
        markExcludedFromBackup(receiptURL)
      }
    }
    if isReplacingExistingModel {
      try fileManager.moveItem(at: destinationURL, to: backupURL)
      markExcludedFromBackup(backupURL)
      if fileManager.fileExists(atPath: receiptURL.path) {
        do {
          try fileManager.moveItem(at: receiptURL, to: receiptBackupURL)
          didMoveReceiptToBackup = true
          markExcludedFromBackup(receiptBackupURL)
        } catch {
          restoreBackups()
          throw error
        }
      }
      do {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
      } catch {
        restoreBackups()
        throw error
      }
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
    markExcludedFromBackup(destinationURL)
    do {
      didStartWritingNewReceipt = true
      try QixiNativeModelInstallReceiptStore.writeReceipt(
        forModelAt: destinationURL,
        spec: spec,
        fileManager: fileManager
      )
    } catch {
      restoreBackups()
      throw error
    }
    if fileManager.fileExists(atPath: backupURL.path) {
      try? fileManager.removeItem(at: backupURL)
    }
    if fileManager.fileExists(atPath: receiptBackupURL.path) {
      try? fileManager.removeItem(at: receiptBackupURL)
    }

    return NativeKataGoInstalledModel(
      resolvedModel: NativeKataGoResolvedModel(spec: spec, fileURL: destinationURL),
      integrityReport: copiedReport
    )
  }

  func installRecognizedModel(
    from sourceURL: URL,
    specs: [NativeKataGoModelSpec] = QixiNativeModelRegistry.allSpecs(),
    chunkByteCount: Int = QixiNativeModelIntegrity.defaultHashChunkByteCount
  ) throws -> NativeKataGoInstalledModel {
    let spec = try recognizedModelSpec(for: sourceURL, specs: specs, chunkByteCount: chunkByteCount)
    return try installVerifiedModel(from: sourceURL, spec: spec, chunkByteCount: chunkByteCount)
  }

  static func isCoreMLPackageURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "mlpackage" || ext == "mlmodelc"
  }

  func installVerifiedCoreMLPackage(
    from sourceURL: URL,
    match: NativeKataGoCoreMLPackageMatch,
    chunkByteCount: Int = QixiNativeCoreMLPackageIntegrity.defaultHashChunkByteCount
  ) throws -> NativeKataGoInstalledCoreMLPackage {
    _ = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
      at: sourceURL,
      packageSpec: match.packageSpec,
      fileManager: fileManager,
      chunkByteCount: chunkByteCount
    )

    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: modelsDirectory,
      label: "Qixi native model install directory",
      fileManager: fileManager
    )
    markExcludedFromBackup(modelsDirectory)
    QixiNativeModelInstallArtifactCleaner.cleanupOrphanedArtifacts(
      in: modelsDirectory,
      fileManager: fileManager,
      excluding: [sourceURL]
    )

    let destinationURL = modelsDirectory.appendingTrustedRelativePath(match.packageSpec.resourceName, isDirectory: true)
    let destinationDirectory = destinationURL.deletingLastPathComponent()
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: destinationDirectory,
      label: "Qixi native CoreML package install directory",
      fileManager: fileManager
    )
    markExcludedFromBackup(destinationDirectory)
    QixiNativeModelInstallArtifactCleaner.cleanupOrphanedCoreMLPackageArtifacts(
      in: destinationDirectory,
      fileManager: fileManager,
      excluding: [sourceURL]
    )

    let temporaryURL = destinationDirectory.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).\(UUID().uuidString).coreml-package-tmp",
      isDirectory: true
    )
    let backupURL = destinationDirectory.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).\(UUID().uuidString).coreml-package-backup",
      isDirectory: true
    )
    let receiptURL = QixiNativeCoreMLPackageInstallReceiptStore.receiptURL(forPackageAt: destinationURL)
    let receiptBackupURL = destinationDirectory.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).\(UUID().uuidString).coreml-package-receipt-backup"
    )
    if fileManager.fileExists(atPath: temporaryURL.path) {
      try fileManager.removeItem(at: temporaryURL)
    }
    defer {
      if fileManager.fileExists(atPath: temporaryURL.path) {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    try fileManager.copyItem(at: sourceURL, to: temporaryURL)
    markExcludedFromBackup(temporaryURL)
    let copiedReport = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
      at: temporaryURL,
      packageSpec: match.packageSpec,
      fileManager: fileManager,
      chunkByteCount: chunkByteCount
    )

    let isReplacingExistingPackage = fileManager.fileExists(atPath: destinationURL.path)
    var didMoveReceiptToBackup = false
    var didStartWritingNewReceipt = false
    let restoreBackups = {
      if self.fileManager.fileExists(atPath: destinationURL.path) {
        try? self.fileManager.removeItem(at: destinationURL)
      }
      if self.fileManager.fileExists(atPath: backupURL.path) {
        try? self.fileManager.moveItem(at: backupURL, to: destinationURL)
        self.markExcludedFromBackup(destinationURL)
      }
      if didStartWritingNewReceipt && self.fileManager.fileExists(atPath: receiptURL.path) {
        try? self.fileManager.removeItem(at: receiptURL)
      }
      if didMoveReceiptToBackup && self.fileManager.fileExists(atPath: receiptBackupURL.path) {
        try? self.fileManager.moveItem(at: receiptBackupURL, to: receiptURL)
        self.markExcludedFromBackup(receiptURL)
      }
    }
    if isReplacingExistingPackage {
      try fileManager.moveItem(at: destinationURL, to: backupURL)
      markExcludedFromBackup(backupURL)
      if fileManager.fileExists(atPath: receiptURL.path) {
        do {
          try fileManager.moveItem(at: receiptURL, to: receiptBackupURL)
          didMoveReceiptToBackup = true
          markExcludedFromBackup(receiptBackupURL)
        } catch {
          restoreBackups()
          throw error
        }
      }
      do {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
      } catch {
        restoreBackups()
        throw error
      }
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
    markExcludedFromBackup(destinationURL)
    do {
      didStartWritingNewReceipt = true
      try QixiNativeCoreMLPackageInstallReceiptStore.writeReceipt(
        forPackageAt: destinationURL,
        packageSpec: match.packageSpec,
        fileManager: fileManager,
        chunkByteCount: chunkByteCount
      )
    } catch {
      restoreBackups()
      throw error
    }
    if fileManager.fileExists(atPath: backupURL.path) {
      try? fileManager.removeItem(at: backupURL)
    }
    if fileManager.fileExists(atPath: receiptBackupURL.path) {
      try? fileManager.removeItem(at: receiptBackupURL)
    }

    return NativeKataGoInstalledCoreMLPackage(
      modelSpec: match.modelSpec,
      packageSpec: match.packageSpec,
      packageURL: destinationURL,
      integrityReport: copiedReport
    )
  }

  func installRecognizedCoreMLPackage(
    from sourceURL: URL,
    matches: [NativeKataGoCoreMLPackageMatch] = QixiNativeModelRegistry.allCoreMLPackageMatches(),
    chunkByteCount: Int = QixiNativeCoreMLPackageIntegrity.defaultHashChunkByteCount
  ) throws -> NativeKataGoInstalledCoreMLPackage {
    let match = try recognizedCoreMLPackageMatch(
      for: sourceURL,
      matches: matches,
      chunkByteCount: chunkByteCount
    )
    return try installVerifiedCoreMLPackage(
      from: sourceURL,
      match: match,
      chunkByteCount: chunkByteCount
    )
  }

  func recognizedCoreMLPackageMatch(
    for sourceURL: URL,
    matches: [NativeKataGoCoreMLPackageMatch] = QixiNativeModelRegistry.allCoreMLPackageMatches(),
    chunkByteCount: Int = QixiNativeCoreMLPackageIntegrity.defaultHashChunkByteCount
  ) throws -> NativeKataGoCoreMLPackageMatch {
    let sizeMatchingMatches = matches.filter {
      QixiNativeCoreMLPackageIntegrity.quickPackageMatchesManifest(
        sourceURL,
        packageSpec: $0.packageSpec,
        fileManager: fileManager
      )
    }
    guard !sizeMatchingMatches.isEmpty else {
      throw QixiNativeModelInstallerError.unrecognizedCoreMLPackage(sourceURL.lastPathComponent)
    }

    var lastFailure: Error?
    for match in sizeMatchingMatches {
      do {
        _ = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
          at: sourceURL,
          packageSpec: match.packageSpec,
          fileManager: fileManager,
          chunkByteCount: chunkByteCount
        )
        return match
      } catch {
        lastFailure = error
      }
    }
    throw lastFailure ?? QixiNativeModelInstallerError.unrecognizedCoreMLPackage(sourceURL.lastPathComponent)
  }

  func recognizedModelSpec(
    for sourceURL: URL,
    specs: [NativeKataGoModelSpec] = QixiNativeModelRegistry.allSpecs(),
    chunkByteCount: Int = QixiNativeModelIntegrity.defaultHashChunkByteCount
  ) throws -> NativeKataGoModelSpec {
    let sizeMatchingSpecs = specs.filter {
      QixiNativeModelIntegrity.byteCountMatchesManifest(sourceURL, spec: $0, fileManager: fileManager)
    }
    guard !sizeMatchingSpecs.isEmpty else {
      throw QixiNativeModelInstallerError.unrecognizedModel(sourceURL.lastPathComponent)
    }

    var lastFailure: Error?
    for spec in sizeMatchingSpecs {
      do {
        _ = try QixiNativeModelIntegrity.verifyModel(
          at: sourceURL,
          spec: spec,
          fileManager: fileManager,
          chunkByteCount: chunkByteCount
        )
        return spec
      } catch {
        lastFailure = error
      }
    }
    throw lastFailure ?? QixiNativeModelInstallerError.unrecognizedModel(sourceURL.lastPathComponent)
  }

  private func markExcludedFromBackup(_ url: URL) {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? mutableURL.setResourceValues(values)
  }
}
