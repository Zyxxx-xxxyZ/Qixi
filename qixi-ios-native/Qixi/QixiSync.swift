import Foundation

enum QixiSyncProvider: String, Codable, Equatable {
  case iCloud
  case localFallback
}

struct QixiSyncStatus: Equatable {
  var provider: QixiSyncProvider = .localFallback
  var lastSyncAt: Date?
  var lastError: String?
  /// Human-readable where-to-look / what was written after the last successful sync.
  var lastDetail: String?
}

struct QixiSyncResult: Equatable {
  var provider: QixiSyncProvider
  var snapshotURL: URL
  var backupSnapshotURL: URL
  var importedSnapshot: QixiAppSnapshot?
  /// Files that exist under the public Documents root after this sync.
  var visibleDocumentNames: [String] = []
}

enum QixiSyncError: Error, Equatable, LocalizedError {
  case incompatibleRemoteSnapshot(URL)
  case unreadableRemoteSnapshot(URL)
  case conflictingRemoteSnapshot(URL)
  case ubiquityWriteVerificationFailed(String)

  var errorDescription: String? {
    switch self {
    case .incompatibleRemoteSnapshot(let url):
      return "Remote Qixi snapshot exists but uses an incompatible schema: \(url.path)"
    case .unreadableRemoteSnapshot(let url):
      return "Remote Qixi snapshot exists but could not be read safely: \(url.path)"
    case .conflictingRemoteSnapshot(let url):
      return "Remote Qixi snapshot has the same timestamp as local state but different content: \(url.path)"
    case .ubiquityWriteVerificationFailed(let detail):
      return "iCloud write could not be verified: \(detail)"
    }
  }
}

enum QixiSyncStore {
  static let containerIdentifier = "iCloud.com.qixi.localanalysis"
  /// Flat under the public Documents folder so Files app shows them at the Qixi iCloud root.
  /// Note: users open Files → iCloud Drive → **Qixi** (NSUbiquitousContainerName), not a
  /// nested path named Documents/Qixi. The "Documents/" prefix is the container-internal
  /// public root that Files presents as the Qixi folder itself.
  static let syncRelativePath = "Documents/autosave.qixi-state.json"
  static let syncBackupRelativePath = "Documents/autosave.qixi-state.backup.json"
  /// Pre-flatten paths — still read for migration after an older install synced.
  static let legacySyncRelativePath = "Documents/Qixi/autosave.qixi-state.json"
  static let legacySyncBackupRelativePath = "Documents/Qixi/autosave.qixi-state.backup.json"
  static let visibleMCTSStatePackageRelativePath = "Documents/Qixi Search State.qixi.png"
  static let visibleMCTSStatePackageFilename = "Qixi Search State.qixi.png"
  static let visibleCurrentGameSGFRelativePath = "Documents/Current Game.sgf"
  static let visibleCurrentGameSGFFilename = "Current Game.sgf"
  /// Independent archives under a long, product-specific folder name (avoids short-name clashes in iCloud Drive).
  static let archivesDirectoryName = "Qixi Game Analysis Archives"
  static let archivesDirectoryRelativePath = "Documents/\(archivesDirectoryName)"
  /// Pre-rename path still scanned for listing older installs.
  static let legacyArchivesDirectoryRelativePath = "Documents/Archives"

  static var currentProvider: QixiSyncProvider {
    destinationURLs().provider
  }

  static func launchSyncEnabled(
    requestedEnabled: Bool,
    automationOverride: Bool?,
    provider: QixiSyncProvider = currentProvider
  ) -> Bool {
    if let automationOverride {
      return automationOverride
    }
    return requestedEnabled && provider == .iCloud
  }

  static func persistedICloudEnabled(afterSyncWith provider: QixiSyncProvider) -> Bool {
    provider == .iCloud
  }

  private struct RemoteSnapshotRead {
    var provider: QixiSyncProvider
    var primaryURL: URL
    var backupURL: URL
    var selectedURL: URL
    var snapshot: QixiAppSnapshot?
    var needsMirrorRepair: Bool
  }

  static func preferredSnapshot(localSnapshot: QixiAppSnapshot?) throws -> QixiAppSnapshot? {
    let remote = try readSnapshot()
    guard let remoteSnapshot = remote.snapshot else {
      return localSnapshot
    }
    guard let localSnapshot else {
      return remoteSnapshot
    }
    if remoteSnapshot.hasSameRestorableState(as: localSnapshot) {
      return localSnapshot
    }
    if remoteSnapshot.savedAt == localSnapshot.savedAt {
      throw QixiSyncError.conflictingRemoteSnapshot(remote.selectedURL)
    }
    return remoteSnapshot.savedAt > localSnapshot.savedAt ? remoteSnapshot : localSnapshot
  }

  static func launchSnapshot(localSnapshot: QixiAppSnapshot?, syncEnabled: Bool) throws -> QixiAppSnapshot? {
    guard syncEnabled else { return localSnapshot }
    return try preferredSnapshot(localSnapshot: localSnapshot)
  }

  static func reconcile(localSnapshot: QixiAppSnapshot?) throws -> QixiSyncResult {
    let remote = try readSnapshot()
    if let remoteSnapshot = remote.snapshot, let localSnapshot {
      if remoteSnapshot.hasSameRestorableState(as: localSnapshot) {
        try repairRemoteMirrorIfNeeded(remote, snapshot: remoteSnapshot)
        return makeResult(
          provider: remote.provider,
          primaryURL: remote.primaryURL,
          backupURL: remote.backupURL,
          importedSnapshot: nil
        )
      }
      if remoteSnapshot.savedAt > localSnapshot.savedAt {
        try QixiSnapshotStore.save(remoteSnapshot)
        try repairRemoteMirrorIfNeeded(remote, snapshot: remoteSnapshot)
        return makeResult(
          provider: remote.provider,
          primaryURL: remote.primaryURL,
          backupURL: remote.backupURL,
          importedSnapshot: remoteSnapshot
        )
      }
      if remoteSnapshot.savedAt == localSnapshot.savedAt {
        throw QixiSyncError.conflictingRemoteSnapshot(remote.selectedURL)
      }
    }
    if let remoteSnapshot = remote.snapshot, localSnapshot == nil {
      try QixiSnapshotStore.save(remoteSnapshot)
      try repairRemoteMirrorIfNeeded(remote, snapshot: remoteSnapshot)
      return makeResult(
        provider: remote.provider,
        primaryURL: remote.primaryURL,
        backupURL: remote.backupURL,
        importedSnapshot: remoteSnapshot
      )
    }

    guard let localSnapshot else {
      return makeResult(
        provider: remote.provider,
        primaryURL: remote.primaryURL,
        backupURL: remote.backupURL,
        importedSnapshot: nil
      )
    }
    try write(localSnapshot)
    return makeResult(
      provider: remote.provider,
      primaryURL: remote.primaryURL,
      backupURL: remote.backupURL,
      importedSnapshot: nil
    )
  }

  static func write(_ snapshot: QixiAppSnapshot) throws {
    let destination = destinationURLs()
    try ensureDocumentsDirectoryExists(for: destination.primaryURL)
    let data = try QixiSnapshotStore.encode(snapshot)
    try writeUbiquityAware(data, to: destination.backupURL)
    try writeUbiquityAware(data, to: destination.primaryURL)
    // Drop legacy nested paths so Files does not show a confusing empty nested folder
    // and so reconcile does not pick a stale nested copy over the flat write.
    try? removeItemIfPresent(at: legacyURL(for: legacySyncRelativePath, fallbackName: QixiSnapshotStore.snapshotFilename))
    try? removeItemIfPresent(at: legacyURL(for: legacySyncBackupRelativePath, fallbackName: QixiSnapshotStore.backupSnapshotFilename))
    try verifyFileExists(at: destination.primaryURL, label: "primary sync snapshot")
  }

  /// True when the system currently exposes the Qixi iCloud ubiquity container.
  static var isICloudContainerAvailable: Bool {
    ubiquityRootURL() != nil
  }

  /// Absolute URL of the public Documents root (what Files shows as the Qixi folder), if any.
  static var publicDocumentsDirectoryURL: URL? {
    guard let root = ubiquityRootURL() else { return nil }
    return root.appendingPathComponent("Documents", isDirectory: true)
  }

  static func listVisibleDocumentNames() -> [String] {
    guard let documents = publicDocumentsDirectoryURL ?? localFallbackDocumentsDirectoryURL() else {
      return []
    }
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: documents,
      includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return urls
      .map(\.lastPathComponent)
      .filter { !$0.hasPrefix(".") }
      .sorted()
  }

  static func visibleMCTSStatePackageDestination() -> (provider: QixiSyncProvider, packageURL: URL) {
    // Sealed image documents are regular files (PNG + payload), not package directories.
    if let ubiquityRoot = ubiquityRootURL() {
      return (
        .iCloud,
        ubiquityRoot.appendingPathComponent(visibleMCTSStatePackageRelativePath, isDirectory: false)
      )
    }
    return (
      .localFallback,
      QixiSnapshotStore.snapshotsDirectory
        .appendingPathComponent("SyncFallback", isDirectory: true)
        .appendingPathComponent(visibleMCTSStatePackageFilename, isDirectory: false)
    )
  }

  @discardableResult
  static func replaceVisibleMCTSStatePackage(with sourcePackageURL: URL) throws -> URL {
    let destination = visibleMCTSStatePackageDestination()
    let packageURL = destination.packageURL
    try ensureDocumentsDirectoryExists(for: packageURL)
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(
      in: packageURL,
      label: "Qixi visible MCTS state package path"
    )
    var coordinatorError: NSError?
    var replaceError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: packageURL,
      options: .forReplacing,
      error: &coordinatorError
    ) { coordinatedURL in
      do {
        if FileManager.default.fileExists(atPath: coordinatedURL.path) {
          try FileManager.default.removeItem(at: coordinatedURL)
        }
        try FileManager.default.copyItem(at: sourcePackageURL, to: coordinatedURL)
      } catch {
        replaceError = error
      }
    }
    if let coordinatorError { throw coordinatorError }
    if let replaceError { throw replaceError }
    // Seal directory packages into PNG-leading files so Files shows board icons.
    try? QixiMCTSStatePackageStore.sealDirectoryPackageAsImageDocument(packageURL)
    try verifyFileExists(at: packageURL, label: "visible MCTS package")
    return packageURL
  }

  /// Fixed path under an archives root: `baseName.ext` (no numeric collision suffix).
  /// WPS-style: same name always means the same file (create or replace).
  static func archivesFileURL(
    preferredBaseName: String,
    pathExtension: String,
    root: URL? = nil
  ) throws -> URL {
    let sanitized = sanitizeFileBaseName(preferredBaseName)
    let archivesRoot = root ?? archivesDirectoryURL()
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: archivesRoot,
      label: "Qixi archives directory"
    )
    // `packageExtension` is `qixi.png` — build the leaf name explicitly.
    let leaf = pathExtension.isEmpty ? sanitized : "\(sanitized).\(pathExtension)"
    let candidate = archivesRoot.appendingPathComponent(leaf, isDirectory: false)
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(
      in: candidate,
      label: "Qixi archive path"
    )
    return candidate
  }

  /// Companion `.sgf` next to a package URL (same directory + base name).
  static func companionSGFURL(forPackageURL packageURL: URL) -> URL {
    let base = displayNameWithoutPackageExtension(packageURL.lastPathComponent)
    return packageURL
      .deletingLastPathComponent()
      .appendingPathComponent(base, isDirectory: false)
      .appendingPathExtension("sgf")
  }

  /// Writes/replaces an archive package at a fixed path under `root`.
  @discardableResult
  static func writeIndependentArchivePackage(
    from sourcePackageURL: URL,
    preferredBaseName: String,
    packageExtension: String = QixiMCTSStatePackageStore.packageExtension,
    root: URL? = nil
  ) throws -> URL {
    let candidate = try archivesFileURL(
      preferredBaseName: preferredBaseName,
      pathExtension: packageExtension,
      root: root
    )
    try replacePackage(at: candidate, with: sourcePackageURL)
    return candidate
  }

  /// Writes/replaces a `.sgf` at a fixed path under `root`.
  @discardableResult
  static func writeIndependentSGFFile(
    text: String,
    preferredBaseName: String,
    root: URL? = nil
  ) throws -> URL {
    let candidate = try archivesFileURL(
      preferredBaseName: preferredBaseName,
      pathExtension: "sgf",
      root: root
    )
    try replaceSGFFile(at: candidate, text: text)
    return candidate
  }

  /// Overwrites a package in place (WPS Save on an existing file).
  static func replacePackage(at destinationURL: URL, with sourcePackageURL: URL) throws {
    try QixiMCTSStatePackageStore.sealDirectoryPackageAsImageDocument(sourcePackageURL)
    try copyReplacingItem(
      from: sourcePackageURL,
      to: destinationURL,
      label: "replace archive package"
    )
    try QixiMCTSStatePackageStore.sealDirectoryPackageAsImageDocument(destinationURL)
    try verifyFileExists(at: destinationURL, label: "replaced archive package")
  }

  /// Overwrites a plain `.sgf` file in place.
  static func replaceSGFFile(at destinationURL: URL, text: String) throws {
    guard let data = text.data(using: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(
      in: destinationURL,
      label: "replace archive SGF"
    )
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: destinationURL.deletingLastPathComponent(),
      label: "Qixi archive SGF parent"
    )
    var coordinatorError: NSError?
    var writeError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinatorError
    ) { coordinatedURL in
      do {
        if FileManager.default.fileExists(atPath: coordinatedURL.path) {
          try FileManager.default.removeItem(at: coordinatedURL)
        }
        try data.write(to: coordinatedURL, options: [.atomic])
      } catch {
        writeError = error
      }
    }
    if let coordinatorError { throw coordinatorError }
    if let writeError { throw writeError }
    try verifyFileExists(at: destinationURL, label: "replaced archive SGF")
  }

  private static func copyReplacingItem(from sourceURL: URL, to destinationURL: URL, label: String) throws {
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(in: destinationURL, label: label)
    var coordinatorError: NSError?
    var copyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinatorError
    ) { coordinatedURL in
      do {
        if FileManager.default.fileExists(atPath: coordinatedURL.path) {
          try FileManager.default.removeItem(at: coordinatedURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: coordinatedURL)
      } catch {
        copyError = error
      }
    }
    if let coordinatorError { throw coordinatorError }
    if let copyError { throw copyError }
  }

  static func archivesDirectoryURL() -> URL {
    if let ubiquityRoot = ubiquityRootURL() {
      return ubiquityRoot.appendingPathComponent(archivesDirectoryRelativePath, isDirectory: true)
    }
    return localArchivesDirectoryURL()
  }

  /// Always-local archives root (Application Support), independent of iCloud.
  static func localArchivesDirectoryURL() -> URL {
    QixiSnapshotStore.snapshotsDirectory
      .appendingPathComponent(archivesDirectoryName, isDirectory: true)
  }

  /// iCloud Drive archives root when ubiquity is available; otherwise nil.
  static func iCloudArchivesDirectoryURL() -> URL? {
    guard let ubiquityRoot = ubiquityRootURL() else { return nil }
    return ubiquityRoot.appendingPathComponent(archivesDirectoryRelativePath, isDirectory: true)
  }

  /// Back-compat alias; canonical type lives in `QixiModels` as `QixiArchiveListItem`.
  typealias ArchiveListItem = QixiArchiveListItem

  /// Local + iCloud (when the ubiquity container is available) `.qixi.png` packages, newest first.
  /// No user enablement flag — R/W on the app container does not require in-app authorization.
  static func listArchivePackages() -> [QixiArchiveListItem] {
    var items: [QixiArchiveListItem] = []
    var seen = Set<String>()

    func appendPackages(in directory: URL, isICloud: Bool) {
      let fm = FileManager.default
      guard let entries = try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey, .ubiquitousItemDownloadingStatusKey],
        options: [.skipsHiddenFiles]
      ) else { return }
      for url in entries {
        let name = url.lastPathComponent
        guard QixiMCTSStatePackageStore.filenameLooksLikePackage(name) else { continue }
        let key = url.standardizedFileURL.path
        if seen.contains(key) { continue }
        seen.insert(key)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let date = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
        let base = displayNameWithoutPackageExtension(name)
        items.append(
          QixiArchiveListItem(
            url: url,
            displayName: base,
            sortDate: date,
            isICloud: isICloud
          )
        )
      }
    }

    // Local Application Support archives (+ legacy folder name).
    let localRoots = [
      localArchivesDirectoryURL(),
      QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("Archives", isDirectory: true),
    ]
    for root in localRoots {
      appendPackages(in: root, isICloud: false)
    }

    // iCloud when available: current long-name folder + legacy "Archives".
    if let ubiquity = ubiquityRootURL() {
      let cloudRoots = [
        ubiquity.appendingPathComponent(archivesDirectoryRelativePath, isDirectory: true),
        ubiquity.appendingPathComponent(legacyArchivesDirectoryRelativePath, isDirectory: true),
      ]
      for root in cloudRoots {
        // Kick off downloads for offline items (best-effort).
        if let entries = try? FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        ) {
          for url in entries where QixiMCTSStatePackageStore.filenameLooksLikePackage(url.lastPathComponent) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
          }
        }
        appendPackages(in: root, isICloud: true)
      }
    }

    items.sort { lhs, rhs in
      if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
    return items
  }

  static func displayNameWithoutPackageExtension(_ filename: String) -> String {
    var name = filename
    for suffix in QixiMCTSStatePackageStore.allPackageFilenameSuffixes {
      let ext = ".\(suffix)"
      if name.lowercased().hasSuffix(ext.lowercased()) {
        name = String(name.dropLast(ext.count))
        break
      }
    }
    return name
  }

  /// Writes/replaces SGF + package under local Archives and, when available, the same basenames on iCloud.
  /// Fixed names only — no `(2)` collision suffixes (WPS-style replace).
  @discardableResult
  static func writeArchiveAndSync(
    sgfText: String,
    packageSourceURL: URL,
    preferredBaseName: String
  ) throws -> (localPackage: URL, localSGF: URL, cloudPackage: URL?, cloudSGF: URL?) {
    let base = sanitizeFileBaseName(preferredBaseName)
    let localPackage = try writeIndependentArchivePackage(
      from: packageSourceURL,
      preferredBaseName: base,
      root: localArchivesDirectoryURL()
    )
    let localSGF = try writeIndependentSGFFile(
      text: sgfText,
      preferredBaseName: base,
      root: localArchivesDirectoryURL()
    )
    var cloudPackage: URL?
    var cloudSGF: URL?
    if let cloudRoot = iCloudArchivesDirectoryURL() {
      cloudPackage = try? writeIndependentArchivePackage(
        from: packageSourceURL,
        preferredBaseName: base,
        root: cloudRoot
      )
      cloudSGF = try? writeIndependentSGFFile(
        text: sgfText,
        preferredBaseName: base,
        root: cloudRoot
      )
    }
    return (localPackage, localSGF, cloudPackage, cloudSGF)
  }

  /// Replaces an already-open archive package (+ companion SGF) in place, and mirrors
  /// the same basename under local / iCloud archive folders when available.
  @discardableResult
  static func replaceExistingArchive(
    packageDestinationURL: URL,
    packageSourceURL: URL,
    sgfText: String,
    baseName: String
  ) throws -> (packageURL: URL, sgfURL: URL) {
    let access = packageDestinationURL.startAccessingSecurityScopedResource()
    defer {
      if access { packageDestinationURL.stopAccessingSecurityScopedResource() }
    }
    try replacePackage(at: packageDestinationURL, with: packageSourceURL)
    QixiBoardThumbnailRenderer.applyStoredPackageIcon(in: packageDestinationURL)
    let sgfURL = companionSGFURL(forPackageURL: packageDestinationURL)
    try replaceSGFFile(at: sgfURL, text: sgfText)
    // Keep the standard archive folders in sync under the same basename.
    _ = try? writeArchiveAndSync(
      sgfText: sgfText,
      packageSourceURL: packageSourceURL,
      preferredBaseName: baseName
    )
    return (packageDestinationURL, sgfURL)
  }

  static func sanitizeFileBaseName(_ raw: String) -> String {
    QixiMCTSStatePackageStore.sanitizeFileBaseName(raw)
  }

  static func defaultArchiveBaseName(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return "Qixi \(formatter.string(from: date))"
  }

  static func visibleCurrentGameSGFDestination() -> (provider: QixiSyncProvider, fileURL: URL) {
    if let ubiquityRoot = ubiquityRootURL() {
      return (
        .iCloud,
        ubiquityRoot.appendingPathComponent(visibleCurrentGameSGFRelativePath, isDirectory: false)
      )
    }
    return (
      .localFallback,
      QixiSnapshotStore.snapshotsDirectory
        .appendingPathComponent("SyncFallback", isDirectory: true)
        .appendingPathComponent(visibleCurrentGameSGFFilename, isDirectory: false)
    )
  }

  /// Writes the user-visible current-game SGF into the iCloud Documents root (flat).
  @discardableResult
  static func replaceVisibleCurrentGameSGF(with text: String) throws -> URL {
    let destination = visibleCurrentGameSGFDestination()
    let fileURL = destination.fileURL
    try ensureDocumentsDirectoryExists(for: fileURL)
    guard let data = text.data(using: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    try writeUbiquityAware(data, to: fileURL)
    try verifyFileExists(at: fileURL, label: "visible current-game SGF")
    return fileURL
  }

  // MARK: - Private

  private static func makeResult(
    provider: QixiSyncProvider,
    primaryURL: URL,
    backupURL: URL,
    importedSnapshot: QixiAppSnapshot?
  ) -> QixiSyncResult {
    QixiSyncResult(
      provider: provider,
      snapshotURL: primaryURL,
      backupSnapshotURL: backupURL,
      importedSnapshot: importedSnapshot,
      visibleDocumentNames: listVisibleDocumentNames()
    )
  }

  /// FileManager-based write that the iCloud daemon (bird) can track.
  /// Avoids low-level open/fsync/rename which often leave files invisible to ubiquity upload.
  private static func writeUbiquityAware(_ data: Data, to url: URL) throws {
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(in: url, label: "Qixi sync path")
    try ensureDocumentsDirectoryExists(for: url)
    var coordinatorError: NSError?
    var writeError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url,
      options: .forReplacing,
      error: &coordinatorError
    ) { coordinatedURL in
      do {
        let parent = coordinatedURL.deletingLastPathComponent()
        let tempURL = parent.appendingPathComponent(
          ".\(coordinatedURL.lastPathComponent).\(UUID().uuidString).partial",
          isDirectory: false
        )
        if FileManager.default.fileExists(atPath: tempURL.path) {
          try FileManager.default.removeItem(at: tempURL)
        }
        // Non-atomic write into the coordinated directory (sibling temp).
        try data.write(to: tempURL, options: [])
        // Soft protection so device lock does not block cloud upload permanently.
        try? FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: tempURL.path
        )
        if FileManager.default.fileExists(atPath: coordinatedURL.path) {
          _ = try FileManager.default.replaceItemAt(
            coordinatedURL,
            withItemAt: tempURL,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
          )
        } else {
          try FileManager.default.moveItem(at: tempURL, to: coordinatedURL)
        }
      } catch {
        writeError = error
      }
    }
    if let coordinatorError { throw coordinatorError }
    if let writeError { throw writeError }
  }

  private static func ensureDocumentsDirectoryExists(for fileURL: URL) throws {
    let parent = fileURL.deletingLastPathComponent()
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: parent,
      label: "Qixi sync Documents directory"
    )
  }

  private static func verifyFileExists(at url: URL, label: String) throws {
    // Packages are directories with an extension; regular files are files.
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard exists else {
      throw QixiSyncError.ubiquityWriteVerificationFailed(
        "\(label) missing after write: \(url.path)"
      )
    }
  }

  private static func readSnapshot() throws -> RemoteSnapshotRead {
    let destination = destinationURLs()
    let primary = try readSnapshotCandidate(at: destination.primaryURL)
    let backup = try readSnapshotCandidate(at: destination.backupURL)
    let legacyPrimary = try readSnapshotCandidate(
      at: legacyURL(for: legacySyncRelativePath, fallbackName: QixiSnapshotStore.snapshotFilename)
    )
    let legacyBackup = try readSnapshotCandidate(
      at: legacyURL(for: legacySyncBackupRelativePath, fallbackName: QixiSnapshotStore.backupSnapshotFilename)
    )
    let allReads = [primary, backup, legacyPrimary, legacyBackup]
    let validCandidates = allReads.compactMap { candidate -> (url: URL, snapshot: QixiAppSnapshot)? in
      guard case .success(let snapshot) = candidate.result else { return nil }
      return (candidate.url, snapshot)
    }

    if validCandidates.isEmpty {
      if case .failure(let primaryError)? = primary.result {
        throw primaryError
      }
      if case .failure(let backupError)? = backup.result {
        throw backupError
      }
      if case .failure(let legacyPrimaryError)? = legacyPrimary.result {
        throw legacyPrimaryError
      }
      if case .failure(let legacyBackupError)? = legacyBackup.result {
        throw legacyBackupError
      }
      return RemoteSnapshotRead(
        provider: destination.provider,
        primaryURL: destination.primaryURL,
        backupURL: destination.backupURL,
        selectedURL: destination.primaryURL,
        snapshot: nil,
        needsMirrorRepair: false
      )
    }

    guard let firstCandidate = validCandidates.first else {
      return RemoteSnapshotRead(
        provider: destination.provider,
        primaryURL: destination.primaryURL,
        backupURL: destination.backupURL,
        selectedURL: destination.primaryURL,
        snapshot: nil,
        needsMirrorRepair: false
      )
    }
    let selected = try newestConsistentSnapshot(
      startingWith: firstCandidate,
      remainingCandidates: validCandidates.dropFirst()
    )
    // Always re-mirror onto flat primary/backup when we recovered from a legacy path
    // or either flat file is missing/stale.
    let needsMirrorRepair = snapshotCandidateNeedsMirrorRepair(primary.result, selected: selected.snapshot) ||
      snapshotCandidateNeedsMirrorRepair(backup.result, selected: selected.snapshot)
    return RemoteSnapshotRead(
      provider: destination.provider,
      primaryURL: destination.primaryURL,
      backupURL: destination.backupURL,
      selectedURL: selected.url,
      snapshot: selected.snapshot,
      needsMirrorRepair: needsMirrorRepair
    )
  }

  private static func repairRemoteMirrorIfNeeded(
    _ remote: RemoteSnapshotRead,
    snapshot: QixiAppSnapshot
  ) throws {
    guard remote.needsMirrorRepair else { return }
    try write(snapshot)
  }

  private static func snapshotCandidateNeedsMirrorRepair(
    _ result: Result<QixiAppSnapshot, QixiSyncError>?,
    selected: QixiAppSnapshot
  ) -> Bool {
    guard case .success(let snapshot)? = result else { return true }
    return snapshot != selected
  }

  private static func newestConsistentSnapshot(
    startingWith firstCandidate: (url: URL, snapshot: QixiAppSnapshot),
    remainingCandidates: ArraySlice<(url: URL, snapshot: QixiAppSnapshot)>
  ) throws -> (url: URL, snapshot: QixiAppSnapshot) {
    var selected = firstCandidate
    for candidate in remainingCandidates {
      if candidate.snapshot.savedAt == selected.snapshot.savedAt &&
        !candidate.snapshot.hasSameRestorableState(as: selected.snapshot) {
        throw QixiSyncError.conflictingRemoteSnapshot(candidate.url)
      }
      if candidate.snapshot.savedAt > selected.snapshot.savedAt {
        selected = candidate
      }
    }
    return selected
  }

  private static func readSnapshotCandidate(
    at url: URL
  ) throws -> (url: URL, result: Result<QixiAppSnapshot, QixiSyncError>?) {
    guard FileManager.default.fileExists(atPath: url.path) else {
      // Start download if this is a dataless ubiquity placeholder we cannot yet see as present.
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      return (url, nil)
    }
    var coordinatorError: NSError?
    var readResult: Result<QixiAppSnapshot, QixiSyncError>?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url,
      options: [],
      error: &coordinatorError
    ) { coordinatedURL in
      do {
        guard let snapshot = try QixiSnapshotStore.decode(from: coordinatedURL) else {
          readResult = .failure(QixiSyncError.incompatibleRemoteSnapshot(coordinatedURL))
          return
        }
        readResult = .success(snapshot)
      } catch let error as QixiSyncError {
        readResult = .failure(error)
      } catch {
        readResult = .failure(QixiSyncError.unreadableRemoteSnapshot(coordinatedURL))
      }
    }
    if let coordinatorError { throw coordinatorError }
    return (url, readResult)
  }

  private static func destinationURLs() -> (provider: QixiSyncProvider, primaryURL: URL, backupURL: URL) {
    if let ubiquityRoot = ubiquityRootURL() {
      // Ensure the public Documents folder exists so Files can publish the Qixi folder.
      let documents = ubiquityRoot.appendingPathComponent("Documents", isDirectory: true)
      try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
      return (
        .iCloud,
        ubiquityRoot.appendingPathComponent(syncRelativePath, isDirectory: false),
        ubiquityRoot.appendingPathComponent(syncBackupRelativePath, isDirectory: false)
      )
    }
    return (.localFallback, fallbackURL, fallbackBackupURL)
  }

  private static func legacyURL(for relativePath: String, fallbackName: String) -> URL {
    if let ubiquityRoot = ubiquityRootURL() {
      return ubiquityRoot.appendingPathComponent(relativePath, isDirectory: false)
    }
    return QixiSnapshotStore.snapshotsDirectory
      .appendingPathComponent("SyncFallback", isDirectory: true)
      .appendingPathComponent("Legacy", isDirectory: true)
      .appendingPathComponent(fallbackName, isDirectory: false)
  }

  private static func removeItemIfPresent(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(in: url, label: "Qixi legacy sync path")
    var coordinatorError: NSError?
    var removeError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url,
      options: .forDeleting,
      error: &coordinatorError
    ) { coordinatedURL in
      do {
        try FileManager.default.removeItem(at: coordinatedURL)
      } catch {
        removeError = error
      }
    }
    if let coordinatorError { throw coordinatorError }
    if let removeError { throw removeError }
  }

  private static func ubiquityRootURL() -> URL? {
    // Prefer the explicit container; do not fall back to the default container for the
    // bundle id (com.zyx.qixi.local-device) which is not iCloud.com.qixi.localanalysis.
    FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
  }

  private static func localFallbackDocumentsDirectoryURL() -> URL? {
    QixiSnapshotStore.snapshotsDirectory
      .appendingPathComponent("SyncFallback", isDirectory: true)
  }

  private static var fallbackURL: URL {
    QixiSnapshotStore.snapshotsDirectory
      .appendingPathComponent("SyncFallback", isDirectory: true)
      .appendingPathComponent(QixiSnapshotStore.snapshotFilename, isDirectory: false)
  }

  private static var fallbackBackupURL: URL {
    QixiSnapshotStore.snapshotsDirectory
      .appendingPathComponent("SyncFallback", isDirectory: true)
      .appendingPathComponent(QixiSnapshotStore.backupSnapshotFilename, isDirectory: false)
  }
}
