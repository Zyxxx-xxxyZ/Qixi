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
    enqueue(
      QixiPendingCoreMutation(
        operation: .selectEngine(engine),
        reason: reason,
        optimisticVariationNodeID: nil,
        uiIntentID: nil,
        completion: completion
      ),
      host: host
    )
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
        let result: QixiCoreBackendResult
        switch pending.operation {
        case .request(let queuedRequest):
          let request = queuedRequest.replacingExpectedBackendEpoch(host.coreBackendEpoch)
          result = try await core.submitCoreRequest(request)
        case .selectEngine(let engine):
          let status = try await host.analysisService.setEngine(engine)
          host.recordCoreRuntimeDiagnostic(
            event: "coreBackendSetEngine",
            success: true,
            message: "engine=\(status.engine) engineId=\(status.engineId ?? "") state=\(status.state)"
          )
          result = try await core.latestCoreSnapshot()
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
