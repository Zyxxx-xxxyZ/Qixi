import Foundation

/// Manual Sync Now orchestration (UI + onboarding).
/// Product policy: no autosave / auto-sync — only this path writes local + iCloud snapshots.
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
    // Wait out blocking transitions rather than silently no-op (felt like "Sync dead").
    if host.isBackendInteractionBlocked {
      Task { [weak self, weak host] in
        guard let self, let host else { return }
        for _ in 0..<100 {
          if !host.isBackendInteractionBlocked { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        guard !host.isBackendInteractionBlocked else {
          host.noteSyncMirrorFailure("Sync deferred: backend still busy")
          return
        }
        self.syncNow()
      }
      return
    }
    // Single-flight: cancel in-progress manual sync and any debounced local save
    // so we do not race two writers on the same snapshot paths.
    syncTask?.cancel()
    host.cancelPendingPersistenceSave()
    // Prefer iCloud when the container is available (no user config/authorization).
    if QixiSyncStore.isICloudContainerAvailable, !host.iCloudSyncEnabled {
      host.setICloudSyncEnabled(true)
    }
    let localSnapshot: QixiAppSnapshot
    do {
      localSnapshot = try forceLocalSnapshotForManualSync(host: host)
    } catch {
      host.notePersistenceError(String(describing: error))
      host.noteSyncMirrorFailure(String(describing: error))
      return
    }
    syncTask = Task { [weak self, weak host] in
      guard let host else { return }
      do {
        try Task.checkCancellation()
        // Always push current local state to the sync destination (iCloud when available).
        try QixiSyncStore.write(localSnapshot)
        try Task.checkCancellation()
        let result = try QixiSyncStore.reconcile(localSnapshot: localSnapshot)
        try Task.checkCancellation()
        if let imported = result.importedSnapshot {
          host.applyImportedAppSnapshot(imported)
          host.resumeAnalysisAfterImportedSnapshot()
        }
        try await host.mirrorVisibleMCTSStatePackageAfterManualSync(result: result)
        try Task.checkCancellation()
        host.noteSyncResult(result)
        host.notePersistenceError(nil)
      } catch is CancellationError {
        // Superseded by a newer syncNow — leave status unchanged.
      } catch {
        host.noteSyncMirrorFailure(String(describing: error))
      }
      _ = self
    }
  }

  /// Manual sync always snapshots current UI — even empty new-game state — so iCloud
  /// receives a write (previously "untouched" skipped and looked dead).
  private func forceLocalSnapshotForManualSync(host: QixiSyncFeatureHost) throws -> QixiAppSnapshot {
    host.cancelPendingPersistenceSave()
    let snapshot = host.buildAppSnapshot(reason: "manualSync")
    try QixiSnapshotStore.save(snapshot)
    host.notePersistenceError(nil)
    return snapshot
  }
}
