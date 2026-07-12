import Foundation

/// Manual Sync Now orchestration (UI + onboarding). Autosave iCloud mirror stays on
/// `QixiPersistenceCoordinator` with a separate task.
@MainActor
final class QixiSyncCoordinator {
  private weak var host: QixiSyncFeatureHost?
  private var syncTask: Task<Void, Never>?

  func attach(host: QixiSyncFeatureHost) {
    self.host = host
  }

  func stop() {
    syncTask?.cancel()
    syncTask = nil
    host = nil
  }

  func syncNow() {
    guard let host else { return }
    guard !host.isBackendInteractionBlocked else { return }
    let wasSyncEnabled = host.iCloudSyncEnabled
    let localSnapshot: QixiAppSnapshot?
    do {
      localSnapshot = try localSnapshotForManualSync(host: host)
    } catch {
      host.notePersistenceError(String(describing: error))
      host.noteSyncMirrorFailure(String(describing: error))
      return
    }
    syncTask?.cancel()
    syncTask = Task { [weak self, weak host] in
      guard let host else { return }
      do {
        let result = try QixiSyncStore.reconcile(localSnapshot: localSnapshot)
        if let imported = result.importedSnapshot {
          host.applyImportedAppSnapshot(imported)
          host.resumeAnalysisAfterImportedSnapshot()
        } else if localSnapshot == nil {
          let initialSnapshot = host.buildAppSnapshot(reason: "manualSync")
          try QixiSnapshotStore.save(initialSnapshot)
          try QixiSyncStore.write(initialSnapshot)
          host.notePersistenceError(nil)
        }
        try await host.mirrorVisibleMCTSStatePackageAfterManualSync(result: result)
        host.noteSyncResult(result)
      } catch {
        if !wasSyncEnabled {
          host.setICloudSyncEnabled(false)
        }
        host.noteSyncMirrorFailure(String(describing: error))
      }
      _ = self
    }
  }

  private func localSnapshotForManualSync(host: QixiSyncFeatureHost) throws -> QixiAppSnapshot? {
    // Match prior ViewModel/PersistenceCoordinator semantics for manual sync prep.
    let snapshot = host.buildAppSnapshot(reason: "manualSync")
    guard let persisted = QixiSnapshotStore.load() else {
      guard !host.isUntouchedLaunchDefaultState else {
        host.notePersistenceError(nil)
        return nil
      }
      try QixiSnapshotStore.save(snapshot)
      host.notePersistenceError(nil)
      return snapshot
    }
    guard !snapshot.hasSameRestorableState(as: persisted) else {
      host.notePersistenceError(nil)
      return persisted
    }
    try QixiSnapshotStore.save(snapshot)
    host.notePersistenceError(nil)
    return snapshot
  }
}
