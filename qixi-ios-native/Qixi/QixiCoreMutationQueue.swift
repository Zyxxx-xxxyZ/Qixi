import Foundation

enum QixiQueuedCoreOperation {
  case request(QixiCoreRequest)
  case selectEngine(AnalysisEngine)
}

struct QixiPendingCoreMutation {
  var operation: QixiQueuedCoreOperation
  var reason: String
  var optimisticVariationNodeID: String?
  var uiIntentID: UInt64?
  var completion: (@MainActor (Bool) -> Void)?
}

struct QixiCoreBarrierError: Error, LocalizedError {
  let operation: String
  let backendMessage: String?

  var errorDescription: String? {
    if let backendMessage, !backendMessage.isEmpty {
      return "Qixi core \(operation) failed: \(backendMessage)"
    }
    return "Qixi core \(operation) failed."
  }
}

/// FIFO queue for core backend mutations.
@MainActor
protocol QixiCoreMutationHost: AnyObject {
  var coreBackendService: (any QixiCoreBackendService)? { get }
  var analysisService: any QixiAnalysisService { get }
  var coreBackendEpoch: UInt64 { get }
  /// UI-selected engine; used to drop superseded model loads still sitting on the queue.
  var selectedEngine: AnalysisEngine { get }

  func applyCoreBackendResult(
    _ result: QixiCoreBackendResult,
    reason: String,
    allowWhileMutationsPending: Bool
  )
  func noteCoreMutationCommittedIntent(
    uiIntentID: UInt64,
    optimisticVariationNodeID: String,
    result: QixiCoreBackendResult
  )
  func recoverFromCoreMutationFailure(
    message: String,
    abandoned: [QixiPendingCoreMutation]
  ) async
  func noteCoreMutationSucceeded(reason: String)
  func recordCoreRuntimeDiagnostic(event: String, success: Bool, message: String)
  /// Build a metrics-only backend result after setEngine (no heavy tree snapshot).
  func makeEngineSelectionResult(engine: AnalysisEngine) -> QixiCoreBackendResult
  /// Mark the engine actually resident in the native core after a successful setEngine.
  func noteCoreEngineSelectionCommitted(_ engine: AnalysisEngine)
  /// Live on-device switch monitor phases (no-op allowed for tests).
  func noteEngineSwitchPhase(_ phase: String, detail: String?)
}

@MainActor
final class QixiCoreMutationQueue {
  private(set) var pendingCount = 0
  private var queue: [QixiPendingCoreMutation] = []
  private var head = 0
  private var pumpTask: Task<Void, Never>?
  private(set) var nextIntentID: UInt64 = 1

  func allocateIntentID() -> UInt64 {
    let id = nextIntentID
    nextIntentID &+= 1
    precondition(nextIntentID != 0, "core intent id overflow")
    return id
  }

  func enqueue(
    _ pending: QixiPendingCoreMutation,
    host: QixiCoreMutationHost
  ) {
    guard host.coreBackendService != nil else {
      pending.completion?(false)
      return
    }
    queue.append(pending)
    pendingCount += 1
    startPumpIfNeeded(host: host)
  }

  func enqueueRequest(
    _ request: QixiCoreRequest,
    reason: String,
    host: QixiCoreMutationHost,
    optimisticVariationNodeID: String? = nil,
    uiIntentID: UInt64? = nil,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    enqueue(
      QixiPendingCoreMutation(
        operation: .request(request),
        reason: reason,
        optimisticVariationNodeID: optimisticVariationNodeID,
        uiIntentID: uiIntentID,
        completion: completion
      ),
      host: host
    )
  }

  func enqueueEngineSelection(
    _ engine: AnalysisEngine,
    reason: String,
    host: QixiCoreMutationHost,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    // Drop any not-yet-started selectEngine ops — only the latest model pick matters.
    // Completions fire false so superseded UI barriers can release without rollback.
    var kept: [QixiPendingCoreMutation] = []
    var dropped = 0
    for index in head..<queue.count {
      if case .selectEngine = queue[index].operation {
        queue[index].completion?(false)
        dropped += 1
      } else {
        kept.append(queue[index])
      }
    }
    if dropped > 0 {
      queue = Array(queue[0..<head]) + kept
      pendingCount = max(0, pendingCount - dropped)
    }
    // Jump the queue: model switch must not wait behind a backlog of play/jump mutations.
    // The in-flight head (if any) still finishes; the new selectEngine runs next.
    let pending = QixiPendingCoreMutation(
      operation: .selectEngine(engine),
      reason: reason,
      optimisticVariationNodeID: nil,
      uiIntentID: nil,
      completion: completion
    )
    guard host.coreBackendService != nil else {
      completion?(false)
      return
    }
    if head < queue.count {
      queue.insert(pending, at: head)
    } else {
      queue.append(pending)
    }
    pendingCount += 1
    startPumpIfNeeded(host: host)
  }

  func waitForDrain() async {
    while let task = pumpTask {
      await task.value
    }
  }

  func submitAndWait(
    _ request: QixiCoreRequest,
    reason: String,
    host: QixiCoreMutationHost
  ) async throws {
    let succeeded = await withCheckedContinuation { continuation in
      enqueueRequest(request, reason: reason, host: host) { success in
        continuation.resume(returning: success)
      }
    }
    guard succeeded else {
      throw QixiCoreBarrierError(operation: reason, backendMessage: nil)
    }
  }

  func selectEngineAndWait(
    _ engine: AnalysisEngine,
    reason: String,
    host: QixiCoreMutationHost
  ) async throws {
    let succeeded = await withCheckedContinuation { continuation in
      enqueueEngineSelection(engine, reason: reason, host: host) { success in
        continuation.resume(returning: success)
      }
    }
    guard succeeded else {
      throw QixiCoreBarrierError(operation: reason, backendMessage: nil)
    }
  }

  /// Clear remaining queue after a failure (host already notified completions).
  func abandonRemaining() -> [QixiPendingCoreMutation] {
    let abandoned = Array(queue[head...])
    pendingCount = max(0, pendingCount - abandoned.count)
    queue.removeAll(keepingCapacity: true)
    head = 0
    return abandoned
  }

  private func startPumpIfNeeded(host: QixiCoreMutationHost) {
    guard pumpTask == nil else { return }
    guard let core = host.coreBackendService else { return }
    pumpTask = Task { @MainActor [weak self, weak host] in
      guard let self, let host else { return }
      await self.runPump(core: core, host: host)
    }
  }

  private func runPump(core: any QixiCoreBackendService, host: QixiCoreMutationHost) async {
    defer {
      pumpTask = nil
      if head >= queue.count {
        queue.removeAll(keepingCapacity: true)
        head = 0
      } else if host.coreBackendService != nil {
        startPumpIfNeeded(host: host)
      }
    }
    while head < queue.count {
      guard !Task.isCancelled else { return }
      let pending = queue[head]
      head += 1
      do {
        var result: QixiCoreBackendResult
        switch pending.operation {
        case .request(let queuedRequest):
          let request = queuedRequest.replacingExpectedBackendEpoch(host.coreBackendEpoch)
          result = try await core.submitCoreRequest(request)
        case .selectEngine(let engine):
          // Skip loading a model the UI already abandoned (rapid re-picks).
          // Exception: .none (quiesce/unload) must always run — import, model install,
          // and memory pressure request unload while selectedEngine still reflects the
          // previous UI pick. Treating that as "superseded" made open .qixi-mcts fail with
          // coreMCTSStateImportQuiesce failed.
          if engine != .none, host.selectedEngine != engine {
            host.recordCoreRuntimeDiagnostic(
              event: "coreBackendSetEngineSuperseded",
              success: true,
              message: "skip load engine=\(engine.rawValue) selected=\(host.selectedEngine.rawValue)"
            )
            pendingCount = max(0, pendingCount - 1)
            pending.completion?(false)
            continue
          }
          // Wall time for the whole setEngine hop (actor + bridge + core submitAndWait).
          // If this is >> engineSelector_ms from core, the stall is outside NN load.
          host.noteEngineSwitchPhase("setEngine_start", detail: "engine=\(engine.rawValue)")
          // setEngine is detached from the analysis actor (see NativeKataGoAnalysisService);
          // this await should track only configure+loadEngine, not snapshot starvation.
          let setEngineWallStart = ContinuousClock.now
          let status = try await host.analysisService.setEngine(engine)
          let setEngineWallMs = Int((ContinuousClock.now - setEngineWallStart) / .milliseconds(1))
          // If the user picked another *real* model mid-load, do not treat this as live.
          // Quiesce (.none) is never discarded for a mid-flight selection change.
          if engine != .none, host.selectedEngine != engine {
            host.noteEngineSwitchPhase("setEngine_superseded", detail: "wall=\(setEngineWallMs)ms")
            host.recordCoreRuntimeDiagnostic(
              event: "coreBackendSetEngineSuperseded",
              success: true,
              message: "discard load engine=\(engine.rawValue) selected=\(host.selectedEngine.rawValue) setEngine_wall_ms=\(setEngineWallMs)"
            )
            pendingCount = max(0, pendingCount - 1)
            pending.completion?(false)
            continue
          }
          host.noteEngineSwitchPhase(
            "setEngine_status",
            detail: "wall=\(setEngineWallMs)ms state=\(status.state)"
          )
          // Timing from core (nodes / store_MB / engineSelector_ms / …) is in status.state
          // when present; always log the full status for switch diagnosis.
          host.recordCoreRuntimeDiagnostic(
            event: "coreBackendSetEngine",
            success: true,
            message: "engine=\(status.engine) engineId=\(status.engineId ?? "") state=\(status.state) setEngine_wall_ms=\(setEngineWallMs) | SWITCH_TIMING_SEE_CORE_MESSAGE"
          )
          // Keep loadedEngine in sync for selectEngineAndWait paths (import quiesce, etc.).
          host.noteCoreEngineSelectionCommitted(engine)
          // Never pull a full tree snapshot on the engine-switch critical path.
          result = host.makeEngineSelectionResult(engine: engine)
        }
        pendingCount = max(0, pendingCount - 1)
        if !result.ok {
          let abandoned = abandonRemainingAfterCurrent()
          await host.recoverFromCoreMutationFailure(
            message: result.message,
            abandoned: abandoned
          )
          pending.completion?(false)
          return
        }
        if let intentID = pending.uiIntentID,
           result.committedUiIntentId == intentID,
           let optimisticNodeID = pending.optimisticVariationNodeID {
          host.noteCoreMutationCommittedIntent(
            uiIntentID: intentID,
            optimisticVariationNodeID: optimisticNodeID,
            result: result
          )
        }
        host.applyCoreBackendResult(result, reason: pending.reason, allowWhileMutationsPending: false)
        host.noteCoreMutationSucceeded(reason: pending.reason)
        pending.completion?(true)
      } catch {
        pendingCount = max(0, pendingCount - 1)
        let abandoned = abandonRemainingAfterCurrent()
        await host.recoverFromCoreMutationFailure(
          message: String(describing: error),
          abandoned: abandoned
        )
        pending.completion?(false)
        return
      }
    }
    queue.removeAll(keepingCapacity: true)
    head = 0
  }

  private func abandonRemainingAfterCurrent() -> [QixiPendingCoreMutation] {
    let abandoned = Array(queue[head...])
    pendingCount = max(0, pendingCount - abandoned.count)
    queue.removeAll(keepingCapacity: true)
    head = 0
    return abandoned
  }
}
