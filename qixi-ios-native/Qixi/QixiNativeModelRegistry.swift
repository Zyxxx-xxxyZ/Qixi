import Foundation

struct NativeKataGoModelSpec: Equatable {
  var engine: AnalysisEngine
  var resourceName: String
  var expectedByteCount: UInt64
  var sha256HexDigest: String
  var minimumMemoryMB: Int
  var recommendedMemoryMB: Int
  var maximumMemoryMB: Int
  var coreMLPackages: [NativeKataGoCoreMLPackageSpec] = []
}

struct NativeKataGoCoreMLPackageSpec: Equatable {
  var resourceName: String
  var variantID: String
  var expectedFileCount: Int
  var expectedTotalByteCount: UInt64
  var sha256TreeDigest: String
}

struct NativeKataGoResolvedModel: Equatable {
  var spec: NativeKataGoModelSpec
  var fileURL: URL
  var coreMLPackageURLs: [URL] = []
}

struct NativeKataGoMemoryBudgetReport: Equatable {
  var engine: AnalysisEngine
  var physicalMemoryMB: Int
  var reservedSystemMemoryMB: Int
  var availableMemoryMB: Int
  var minimumMemoryMB: Int
  var recommendedMemoryMB: Int
  var maximumMemoryMB: Int
}

struct QixiNativeDeviceMemoryPolicy: Equatable {
  static let defaultReservedSystemMemoryMB = 1024

  var physicalMemoryMB: Int
  var reservedSystemMemoryMB: Int

  init(
    physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
    reservedSystemMemoryMB: Int = Self.defaultReservedSystemMemoryMB
  ) {
    let rawPhysicalMemoryMB = physicalMemoryBytes / 1_048_576
    self.physicalMemoryMB = Int(min(rawPhysicalMemoryMB, UInt64(Int.max)))
    self.reservedSystemMemoryMB = max(0, reservedSystemMemoryMB)
  }

  func report(for spec: NativeKataGoModelSpec) -> NativeKataGoMemoryBudgetReport {
    NativeKataGoMemoryBudgetReport(
      engine: spec.engine,
      physicalMemoryMB: physicalMemoryMB,
      reservedSystemMemoryMB: reservedSystemMemoryMB,
      availableMemoryMB: max(0, physicalMemoryMB - reservedSystemMemoryMB),
      minimumMemoryMB: spec.minimumMemoryMB,
      recommendedMemoryMB: spec.recommendedMemoryMB,
      maximumMemoryMB: spec.maximumMemoryMB
    )
  }

  func canLoad(_ spec: NativeKataGoModelSpec) -> Bool {
    report(for: spec).availableMemoryMB >= spec.minimumMemoryMB
  }
}

enum QixiNativeModelRegistry {
  static func spec(for engine: AnalysisEngine) -> NativeKataGoModelSpec? {
    switch engine {
    case .none:
      return nil
    case .b6:
      return NativeKataGoModelSpec(
        engine: engine,
        resourceName: "g170-b6c96-s175395328-d26788732.bin.gz",
        expectedByteCount: 3827339,
        sha256HexDigest: "f5d32604e3675c480c7c8f6aa579a1ea857135628a0afccc8fa56330fbacd38d",
        minimumMemoryMB: 256,
        recommendedMemoryMB: 512,
        maximumMemoryMB: 768
      )
    case .b18nbt:
      return NativeKataGoModelSpec(
        engine: engine,
        resourceName: "b18nbt.bin",
        expectedByteCount: 105532578,
        sha256HexDigest: "46a623a366ef6ef423fa2055f1b094fd8f64c518c065e7d254a9e0829c192c5c",
        minimumMemoryMB: 1024,
        recommendedMemoryMB: 1536,
        maximumMemoryMB: 2048
      )
    case .b28nbt:
      return NativeKataGoModelSpec(
        engine: engine,
        resourceName: "b28nbt.bin",
        expectedByteCount: 291771656,
        sha256HexDigest: "053d2411c311b5cb8f44d9960e431371460169561401ea35088a030b87337770",
        minimumMemoryMB: 2048,
        recommendedMemoryMB: 3072,
        maximumMemoryMB: 4096
      )
    }
  }

  static func allSpecs() -> [NativeKataGoModelSpec] {
    AnalysisEngine.allCases.compactMap(spec(for:))
  }

  static func allCoreMLPackageMatches() -> [NativeKataGoCoreMLPackageMatch] {
    allSpecs().flatMap { spec in
      spec.coreMLPackages.map {
        NativeKataGoCoreMLPackageMatch(modelSpec: spec, packageSpec: $0)
      }
    }
  }
}

struct NativeKataGoCoreMLPackageMatch: Equatable {
  var modelSpec: NativeKataGoModelSpec
  var packageSpec: NativeKataGoCoreMLPackageSpec
}

struct QixiNativeModelStore {
  private static let modelsDirectoryName = "Models"
  private static let applicationDirectoryName = "Qixi"

  var bundle: Bundle
  var fileManager: FileManager
  var additionalSearchDirectories: [URL]
  var trustedInstallReceiptDirectories: [URL]

  init(
    bundle: Bundle = .main,
    fileManager: FileManager = .default,
    additionalSearchDirectories: [URL] = [],
    trustedInstallReceiptDirectories: [URL]? = nil
  ) {
    self.bundle = bundle
    self.fileManager = fileManager
    self.additionalSearchDirectories = additionalSearchDirectories
    self.trustedInstallReceiptDirectories = trustedInstallReceiptDirectories
      ?? Self.applicationSupportModelsDirectory(fileManager: fileManager).map { [$0] }
      ?? []
  }

  func resolvedModel(for spec: NativeKataGoModelSpec) -> NativeKataGoResolvedModel? {
    cleanupTrustedInstallArtifacts()
    for candidate in candidateURLs(for: spec) where modelFileMatchesManifest(candidate, spec: spec) {
      guard let packageURLs = resolvedCoreMLPackageURLs(for: spec, beside: candidate) else {
        continue
      }
      return NativeKataGoResolvedModel(spec: spec, fileURL: candidate, coreMLPackageURLs: packageURLs)
    }
    return nil
  }

  func candidateURLs(for spec: NativeKataGoModelSpec) -> [URL] {
    var candidates: [URL] = []
    candidates.append(contentsOf: additionalSearchDirectories.map { $0.appendingPathComponent(spec.resourceName) })
    if let bundled = bundle.url(forResource: spec.resourceName, withExtension: nil) {
      candidates.append(bundled)
    }
    if let support = Self.applicationSupportModelsDirectory(fileManager: fileManager) {
      candidates.append(support.appendingPathComponent(spec.resourceName))
    }
    return candidates
  }

  static func applicationSupportModelsDirectory(fileManager: FileManager = .default) -> URL? {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent(applicationDirectoryName, isDirectory: true)
      .appendingPathComponent(modelsDirectoryName, isDirectory: true)
  }

  private func modelFileMatchesManifest(_ url: URL, spec: NativeKataGoModelSpec) -> Bool {
    guard QixiNativeModelIntegrity.byteCountMatchesManifest(url, spec: spec, fileManager: fileManager) else {
      return false
    }
    guard isTrustedInstallReceiptDirectory(url.deletingLastPathComponent()) else {
      return true
    }
    return QixiNativeModelInstallReceiptStore.receiptMatchesManifest(
      forModelAt: url,
      spec: spec,
      fileManager: fileManager
    )
  }

  func coreMLPackageURL(
    for packageSpec: NativeKataGoCoreMLPackageSpec,
    beside modelURL: URL
  ) -> URL {
    modelURL
      .deletingLastPathComponent()
      .appendingTrustedRelativePath(packageSpec.resourceName, isDirectory: true)
  }

  private func resolvedCoreMLPackageURLs(
    for spec: NativeKataGoModelSpec,
    beside modelURL: URL
  ) -> [URL]? {
    var packageURLs: [URL] = []
    for packageSpec in spec.coreMLPackages {
      let packageURL = coreMLPackageURL(for: packageSpec, beside: modelURL)
      guard coreMLPackageMatchesManifest(packageURL, packageSpec: packageSpec) else {
        return nil
      }
      packageURLs.append(packageURL)
    }
    return packageURLs
  }

  private func coreMLPackageMatchesManifest(
    _ url: URL,
    packageSpec: NativeKataGoCoreMLPackageSpec
  ) -> Bool {
    cleanupCoreMLPackageArtifactsIfTrusted(in: url.deletingLastPathComponent())
    guard QixiNativeCoreMLPackageIntegrity.quickPackageMatchesManifest(
      url,
      packageSpec: packageSpec,
      fileManager: fileManager
    ) else {
      return false
    }
    guard isTrustedInstallReceiptDirectory(url.deletingLastPathComponent()) else {
      return true
    }
    return QixiNativeCoreMLPackageInstallReceiptStore.receiptMatchesManifest(
      forPackageAt: url,
      packageSpec: packageSpec,
      fileManager: fileManager
    )
  }

  private func isTrustedInstallReceiptDirectory(_ directory: URL) -> Bool {
    let normalizedDirectory = directory.standardizedFileURL
    return trustedInstallReceiptDirectories.contains {
      let trustedPath = $0.standardizedFileURL.path
      let directoryPath = normalizedDirectory.path
      return directoryPath == trustedPath || directoryPath.hasPrefix(trustedPath + "/")
    }
  }

  private func cleanupTrustedInstallArtifacts() {
    var cleanedPaths = Set<String>()
    for directory in trustedInstallReceiptDirectories {
      let normalizedDirectory = directory.standardizedFileURL
      guard cleanedPaths.insert(normalizedDirectory.path).inserted else { continue }
      QixiNativeModelInstallArtifactCleaner.cleanupOrphanedArtifacts(
        in: normalizedDirectory,
        fileManager: fileManager
      )
    }
  }

  private func cleanupCoreMLPackageArtifactsIfTrusted(in directory: URL) {
    let normalizedDirectory = directory.standardizedFileURL
    guard isTrustedInstallReceiptDirectory(normalizedDirectory) else { return }
    QixiNativeModelInstallArtifactCleaner.cleanupOrphanedCoreMLPackageArtifacts(
      in: normalizedDirectory,
      fileManager: fileManager
    )
  }
}

extension URL {
  func appendingTrustedRelativePath(_ relativePath: String, isDirectory: Bool = false) -> URL {
    let components = relativePath.split(separator: "/").map(String.init)
    var url = self
    for (offset, component) in components.enumerated()
      where !component.isEmpty && component != "." && component != ".." {
      url.appendPathComponent(component, isDirectory: isDirectory && offset == components.count - 1)
    }
    return url
  }
}
