import Foundation
import UIKit

/// Host contract for product OOM unload. Implemented by `QixiViewModel`.
@MainActor
protocol QixiMemoryPressureHost: AnyObject {
  var selectedEngine: AnalysisEngine { get }
  /// Soft: trim UI caches + unload NN (engine → none). Keeps live MCTS store.
  func applySoftMemoryPressureRelief() async
  /// Hard: checkpoint active store then drop it from RAM (core `relieveMemoryPressure`).
  func applyHardMemoryPressureRelief() async
}

/// Observes system memory warnings (and optional footprint thresholds) and runs
/// the tiered product unload policy. Does not own MCTS or NN state itself.
@MainActor
final class QixiMemoryPressurePolicy {
  /// Soft path cooldown between any policy runs.
  static let softCooldown: TimeInterval = 20
  /// Hard store-drop cooldown (unless a second warning arrives after soft).
  static let hardCooldown: TimeInterval = 60
  /// Soft preemptive: footprint ≥ physicalMemory − this reserve.
  static let softFootprintReserveBytes: UInt64 = 512 * 1024 * 1024

  private weak var host: QixiMemoryPressureHost?
  private var observer: NSObjectProtocol?
  private var lastSoftAt: Date?
  private var lastHardAt: Date?
  /// True after a soft relief in the current pressure window; next warning escalates.
  private var softAppliedInWindow = false
  private var isRunning = false

  func start(host: QixiMemoryPressureHost) {
    self.host = host
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.handleMemoryWarning()
      }
    }
  }

  func stop() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
    host = nil
    softAppliedInWindow = false
  }

  /// Called from memory telemetry samples for soft preemptive (Tier A only).
  func noteFootprintSample(physFootprintBytes: UInt64) {
    let physical = ProcessInfo.processInfo.physicalMemory
    guard physical > Self.softFootprintReserveBytes else { return }
    let threshold = physical - Self.softFootprintReserveBytes
    guard physFootprintBytes >= threshold else { return }
    Task { @MainActor in
      await self.runSoftIfAllowed(reason: "footprint")
    }
  }

  private func handleMemoryWarning() async {
    if softAppliedInWindow {
      await runHardIfAllowed(reason: "memoryWarningEscalation")
    } else {
      await runSoftIfAllowed(reason: "memoryWarning")
      // Immediate hard if soft could not unload an engine and store may dominate —
      // still respect hard cooldown; second warning escalates via softAppliedInWindow.
      softAppliedInWindow = true
    }
  }

  private func runSoftIfAllowed(reason: String) async {
    guard let host else { return }
    if isRunning { return }
    if let lastSoftAt, Date().timeIntervalSince(lastSoftAt) < Self.softCooldown { return }
    isRunning = true
    defer { isRunning = false }
    lastSoftAt = Date()
    softAppliedInWindow = true
    print("[QixiMemoryPolicy] soft relief reason=\(reason)")
    await host.applySoftMemoryPressureRelief()
  }

  private func runHardIfAllowed(reason: String) async {
    guard let host else { return }
    if isRunning { return }
    if let lastHardAt, Date().timeIntervalSince(lastHardAt) < Self.hardCooldown {
      // Allow escalation within hard cooldown only when soft already ran recently.
      if !softAppliedInWindow { return }
      if let lastSoftAt, Date().timeIntervalSince(lastSoftAt) > Self.softCooldown {
        return
      }
    }
    isRunning = true
    defer { isRunning = false }
    lastHardAt = Date()
    softAppliedInWindow = false
    print("[QixiMemoryPolicy] hard relief reason=\(reason)")
    await host.applyHardMemoryPressureRelief()
  }
}
