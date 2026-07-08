import Foundation

enum QixiSyncProvider: String, Codable, Equatable {
  case iCloud
  case localFallback
}

struct QixiSyncStatus: Equatable {
  var provider: QixiSyncProvider = .localFallback
  var lastSyncAt: Date?
  var lastError: String?
}

struct QixiSyncResult: Equatable {
  var provider: QixiSyncProvider
  var snapshotURL: URL
  var backupSnapshotURL: URL
  var importedSnapshot: QixiAppSnapshot?
}

enum QixiSyncError: Error, Equatable, LocalizedError {
  case incompatibleRemoteSnapshot(URL)
  case unreadableRemoteSnapshot(URL)
  case conflictingRemoteSnapshot(URL)

  var errorDescription: String? {
    switch self {
    case .incompatibleRemoteSnapshot(let url):
      return "Remote Qixi snapshot exists but uses an incompatible schema: \(url.path)"
    case .unreadableRemoteSnapshot(let url):
      return "Remote Qixi snapshot exists but could not be read safely: \(url.path)"
    case .conflictingRemoteSnapshot(let url):
      return "Remote Qixi snapshot has the same timestamp as local state but different content: \(url.path)"
    }
  }
}

enum QixiSyncStore {
  static let containerIdentifier = "iCloud.com.qixi.localanalysis"
  static let syncRelativePath = "Documents/Qixi/autosave.qixi-state.json"
  static let syncBackupRelativePath = "Documents/Qixi/autosave.qixi-state.backup.json"
  static let visibleMCTSStatePackageRelativePath = "Documents/Qixi Search State.qixi-mcts"
  static let visibleMCTSStatePackageFilename = "Qixi Search State.qixi-mcts"

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
        return QixiSyncResult(
          provider: remote.provider,
          snapshotURL: remote.primaryURL,
          backupSnapshotURL: remote.backupURL,
          importedSnapshot: nil
        )
      }
      if remoteSnapshot.savedAt > localSnapshot.savedAt {
        try QixiSnapshotStore.save(remoteSnapshot)
        try repairRemoteMirrorIfNeeded(remote, snapshot: remoteSnapshot)
        return QixiSyncResult(
          provider: remote.provider,
          snapshotURL: remote.primaryURL,
          backupSnapshotURL: remote.backupURL,
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
      return QixiSyncResult(
        provider: remote.provider,
        snapshotURL: remote.primaryURL,
        backupSnapshotURL: remote.backupURL,
        importedSnapshot: remoteSnapshot
      )
    }

    guard let localSnapshot else {
      return QixiSyncResult(
        provider: remote.provider,
        snapshotURL: remote.primaryURL,
        backupSnapshotURL: remote.backupURL,
        importedSnapshot: nil
      )
    }
    try write(localSnapshot)
    return QixiSyncResult(
      provider: remote.provider,
      snapshotURL: remote.primaryURL,
      backupSnapshotURL: remote.backupURL,
      importedSnapshot: nil
    )
  }

  static func write(_ snapshot: QixiAppSnapshot) throws {
    let destination = destinationURLs()
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: destination.primaryURL.deletingLastPathComponent(),
      label: "Qixi sync snapshot directory"
    )
    let data = try QixiSnapshotStore.encode(snapshot)
    try write(data, to: destination.backupURL)
    try write(data, to: destination.primaryURL)
  }

  static func visibleMCTSStatePackageDestination() -> (provider: QixiSyncProvider, packageURL: URL) {
    if let ubiquityRoot = ubiquityRootURL() {
      return (
        .iCloud,
        ubiquityRoot.appendingPathComponent(visibleMCTSStatePackageRelativePath, isDirectory: true)
      )
    }
    return (
      .localFallback,
      QixiSnapshotStore.snapshotsDirectory
        .appendingPathComponent("SyncFallback", isDirectory: true)
        .appendingPathComponent(visibleMCTSStatePackageFilename, isDirectory: true)
    )
  }

  @discardableResult
  static func replaceVisibleMCTSStatePackage(with sourcePackageURL: URL) throws -> URL {
    let destination = visibleMCTSStatePackageDestination()
    let packageURL = destination.packageURL
    try QixiTrustedFilePath.createDirectoryForTrustedWrite(
      at: packageURL.deletingLastPathComponent(),
      label: "Qixi visible MCTS state package directory"
    )
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
    return packageURL
  }

  private static func write(_ data: Data, to url: URL) throws {
    try QixiTrustedFilePath.rejectSymbolicLinkComponents(in: url, label: "Qixi sync snapshot path")
    var coordinatorError: NSError?
    var writeError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url,
      options: .forReplacing,
      error: &coordinatorError
    ) { coordinatedURL in
      do {
        try QixiTrustedFilePath.writeProtectedDataAtomically(
          data,
          to: coordinatedURL,
          label: "Qixi sync snapshot path"
        )
      } catch {
        writeError = error
      }
    }
    if let coordinatorError { throw coordinatorError }
    if let writeError { throw writeError }
  }

  private static func readSnapshot() throws -> RemoteSnapshotRead {
    let destination = destinationURLs()
    let primary = try readSnapshotCandidate(at: destination.primaryURL)
    let backup = try readSnapshotCandidate(at: destination.backupURL)
    let validCandidates = [primary, backup].compactMap { candidate -> (url: URL, snapshot: QixiAppSnapshot)? in
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
      return (
        .iCloud,
        ubiquityRoot.appendingPathComponent(syncRelativePath, isDirectory: false),
        ubiquityRoot.appendingPathComponent(syncBackupRelativePath, isDirectory: false)
      )
    }
    return (.localFallback, fallbackURL, fallbackBackupURL)
  }

  private static func ubiquityRootURL() -> URL? {
    FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) ??
      FileManager.default.url(forUbiquityContainerIdentifier: nil)
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
