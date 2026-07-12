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

/// Host for autosave / lifecycle persistence policy. Implemented by `QixiViewModel`.
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

  /// After remote sync wins and imports a newer snapshot.
  func applyImportedAppSnapshot(_ snapshot: QixiAppSnapshot)

  var hasCoreBackend: Bool { get }
  func engineTombstoneFilenameIfSupported() -> String?
  func exportEngineTombstoneIfSupported(reason: String)
  func submitCoreAutosaveTick(reason: String)
  func submitCoreEnterBackground(deadlineMs: UInt32, completion: @escaping @MainActor (Bool) -> Void)
  func submitCoreEnterForeground(completion: @escaping @MainActor (Bool) -> Void)
}

/// Owns debounce, periodic autosave, snapshot persist/mirror, and lifecycle tombstone policy.
/// Does not own UI hydrate, MCTS package flows, or full manual sync UI.
@MainActor
final class QixiPersistenceCoordinator {
  static let autosaveInterval: TimeInterval = 20 * 60
  static let saveDebounceNanoseconds: UInt64 = 600_000_000

  private weak var host: QixiPersistenceHost?
  private var saveTask: Task<Void, Never>?
  private var syncTask: Task<Void, Never>?
  private var autosaveTimer: Timer?
  private var lifecycleCheckpointPending = false
  private var enteredBackgroundSinceLastForeground = false

  func attach(host: QixiPersistenceHost) {
    self.host = host
  }

  func stop() {
    saveTask?.cancel()
    saveTask = nil
    syncTask?.cancel()
    syncTask = nil
    autosaveTimer?.invalidate()
    autosaveTimer = nil
    host = nil
  }

  func cancelPendingSave() {
    saveTask?.cancel()
    saveTask = nil
  }

  func startAutosaveTimer() {
    autosaveTimer?.invalidate()
    autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.saveNow(reason: "periodicAutosave")
        if self.host?.hasCoreBackend == true {
          self.host?.submitCoreAutosaveTick(reason: "periodicAutosave")
        }
      }
    }
  }

  func saveSoon(reason: String) {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
      guard !Task.isCancelled else { return }
      self?.saveNow(reason: reason)
    }
  }

  func saveNow(reason: String = "manual") {
    guard let host else { return }
    saveTask?.cancel()
    let snapshot = host.buildAppSnapshot(reason: reason)
    do {
      if reason == "launchReady" {
        try persistIfRestorableStateChanged(snapshot, host: host)
      } else {
        try persist(snapshot, host: host)
      }
      host.notePersistenceError(nil)
    } catch {
      host.notePersistenceError(String(describing: error))
    }
  }

  func handleLifecycleTombstone(reason: String) {
    guard let host else { return }
    let shouldQueueBackendCheckpoint = !enteredBackgroundSinceLastForeground
    enteredBackgroundSinceLastForeground = true
    saveTask?.cancel()
    let snapshot = host.buildAppSnapshot(reason: reason)
    do {
      try persist(snapshot, host: host)
      try QixiLifecycleTombstoneStore.mark(
        snapshot: snapshot,
        reason: reason,
        engineTombstoneFilename: host.engineTombstoneFilenameIfSupported()
      )
      host.notePersistenceError(nil)
      if host.hasCoreBackend && shouldQueueBackendCheckpoint && !lifecycleCheckpointPending {
        lifecycleCheckpointPending = true
        let backgroundTask = QixiEngineTombstoneBackgroundTask(name: "QixiCoreCheckpoint") {}
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let deadlineMs: UInt32 = remaining.isFinite
          ? UInt32(max(0, min(Double(UInt32.max), remaining * 1_000)))
          : 30_000
        host.submitCoreEnterBackground(deadlineMs: deadlineMs) { [weak self] _ in
          self?.lifecycleCheckpointPending = false
          backgroundTask.end()
        }
      } else if !host.hasCoreBackend && shouldQueueBackendCheckpoint {
        host.exportEngineTombstoneIfSupported(reason: reason)
      }
    } catch {
      host.notePersistenceError(String(describing: error))
    }
  }

  func handleLifecycleForeground() {
    guard enteredBackgroundSinceLastForeground else { return }
    enteredBackgroundSinceLastForeground = false
    guard let host, host.hasCoreBackend else { return }
    host.submitCoreEnterForeground { _ in }
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

  private func persist(_ snapshot: QixiAppSnapshot, host: QixiPersistenceHost) throws {
    try QixiSnapshotStore.save(snapshot)
    if host.iCloudSyncEnabled {
      mirrorSnapshotToSync(snapshot, host: host)
    }
  }

  private func persistIfRestorableStateChanged(_ snapshot: QixiAppSnapshot, host: QixiPersistenceHost) throws {
    let didWrite = try QixiSnapshotStore.saveIfRestorableStateChanged(snapshot)
    if didWrite && host.iCloudSyncEnabled {
      mirrorSnapshotToSync(snapshot, host: host)
    }
  }

  private func mirrorSnapshotToSync(_ snapshot: QixiAppSnapshot, host: QixiPersistenceHost) {
    guard !host.isAutomationSyncStatusPinned else { return }
    syncTask?.cancel()
    syncTask = Task { [weak self, weak host] in
      guard let self, let host else { return }
      do {
        guard host.buildAppSnapshot(reason: "syncMirrorProbe").hasSameRestorableState(as: snapshot) else {
          return
        }
        let result = try QixiSyncStore.reconcile(localSnapshot: snapshot)
        if let imported = result.importedSnapshot {
          host.applyImportedAppSnapshot(imported)
        }
        host.noteSyncResult(result)
      } catch {
        host.noteSyncMirrorFailure(String(describing: error))
      }
    }
  }
}
