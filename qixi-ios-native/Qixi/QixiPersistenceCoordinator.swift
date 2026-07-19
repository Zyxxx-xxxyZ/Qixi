import Foundation
import UIKit

/// Shared UIApplication background-task wrapper for lifecycle / tombstone work.
@MainActor
final class QixiEngineTombstoneBackgroundTask {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  init(name: String, expirationHandler: @escaping @MainActor () -> Void) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
      Task { @MainActor in
        expirationHandler()
      }
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}

/// Host for persistence policy. Implemented by `QixiViewModel`.
/// Product: no autosave / auto-sync; manual Sync only.
@MainActor
protocol QixiPersistenceHost: AnyObject {
  func buildAppSnapshot(reason: String) -> QixiAppSnapshot

  var iCloudSyncEnabled: Bool { get }
  var isAutomationSyncStatusPinned: Bool { get }

  func notePersistenceError(_ message: String?)
  /// Successful sync reconcile status (may update iCloud preference).
  func noteSyncResult(_ result: QixiSyncResult)
  /// Mirror/reconcile failure without flipping the iCloud preference.
  func noteSyncMirrorFailure(_ message: String)

  /// After remote snapshot is imported through manual Sync Now.
  func applyImportedAppSnapshot(_ snapshot: QixiAppSnapshot)

  var hasCoreBackend: Bool { get }
  /// Kept for protocol compatibility; product does not run periodic core autosave.
  func submitCoreAutosaveTick(reason: String)
}

/// Persistence coordinator. Product policy: **no autosave and no auto-sync**.
/// Local/iCloud writes happen only via explicit Manual Sync Now (`QixiSyncCoordinator`).
/// Lifecycle tombstones and background/foreground restore remain unsupported.
@MainActor
final class QixiPersistenceCoordinator {
  private weak var host: QixiPersistenceHost?
  private var saveTask: Task<Void, Never>?
  private var syncTask: Task<Void, Never>?

  func attach(host: QixiPersistenceHost) {
    self.host = host
  }

  func stop() {
    saveTask?.cancel()
    saveTask = nil
    syncTask?.cancel()
    syncTask = nil
    host = nil
  }

  func cancelPendingSave() {
    saveTask?.cancel()
    saveTask = nil
  }

  /// Product: autosave timer disabled.
  func startAutosaveTimer() {
    // no-op
  }

  /// Product: debounced auto-save disabled.
  func saveSoon(reason: String) {
    _ = reason
    // no-op
  }

  /// Product: automatic local snapshot writes disabled (manual Sync only).
  func saveNow(reason: String = "manual") {
    _ = reason
    // no-op — use QixiSyncCoordinator / QixiSnapshotStore only for intentional sync.
  }

  /// Prepare a local snapshot for manual sync. Returns nil when launch default is untouched.
  func localSnapshotForManualSync(isUntouchedDefault: Bool) throws -> QixiAppSnapshot? {
    guard let host else { return nil }
    saveTask?.cancel()
    let snapshot = host.buildAppSnapshot(reason: "manualSync")
    guard let persisted = QixiSnapshotStore.load() else {
      guard !isUntouchedDefault else {
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
