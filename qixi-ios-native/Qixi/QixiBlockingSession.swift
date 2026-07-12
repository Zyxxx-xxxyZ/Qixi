import Foundation

/// Owns long-running blocking job state and optional core I/O progress polling.
/// ViewModel publishes `activeBlockingJob` / `backendTransition` from this session.
@MainActor
final class QixiBlockingSession {
  private(set) var backendTransition: QixiBackendTransition?
  private(set) var activeBlockingJob: QixiBlockingJob?

  private var order: [UInt64] = []
  private var byToken: [UInt64: QixiBackendTransition] = [:]
  private var nextToken: UInt64 = 1
  private var ioProgressPollTask: Task<Void, Never>?

  var isBlocked: Bool { activeBlockingJob != nil || backendTransition != nil }

  @discardableResult
  func begin(_ transition: QixiBackendTransition) -> UInt64 {
    let token = nextToken
    nextToken &+= 1
    precondition(nextToken != 0, "backend transition token overflow")
    order.append(token)
    byToken[token] = transition
    backendTransition = transition
    activeBlockingJob = QixiBlockingJob(
      id: token,
      kind: transition.jobKind,
      title: QixiBlockingJob.title(for: transition.jobKind),
      phase: transition.statusText,
      fraction: nil,
      detail: nil,
      blocks: QixiBlockingJob.blocks(for: transition.jobKind)
    )
    return token
  }

  func update(
    _ token: UInt64?,
    phase: String? = nil,
    fraction: Double? = nil,
    detail: String? = nil
  ) {
    guard let token, byToken[token] != nil else { return }
    guard var job = activeBlockingJob, job.id == token else { return }
    if let phase { job.phase = phase }
    if let fraction { job.fraction = min(1.0, max(0.0, fraction)) }
    if let detail { job.detail = detail }
    activeBlockingJob = job
  }

  func finish(_ token: UInt64?) {
    guard let token, byToken.removeValue(forKey: token) != nil else { return }
    order.removeAll { $0 == token }
    backendTransition = order.last.flatMap { byToken[$0] }
    stopIoProgressPolling()
    if let remaining = order.last, let kind = byToken[remaining] {
      activeBlockingJob = QixiBlockingJob(
        id: remaining,
        kind: kind.jobKind,
        title: QixiBlockingJob.title(for: kind.jobKind),
        phase: kind.statusText,
        fraction: nil,
        detail: nil,
        blocks: QixiBlockingJob.blocks(for: kind.jobKind)
      )
    } else {
      activeBlockingJob = nil
    }
  }

  func startIoProgressPolling(
    for token: UInt64,
    service: NativeKataGoAnalysisService,
    onUpdate: @escaping @MainActor (UInt64, String?, Double?, String?) -> Void
  ) {
    stopIoProgressPolling()
    ioProgressPollTask = Task {
      while !Task.isCancelled {
        guard byToken[token] != nil else { return }
        if let progress = try? await service.coreIoProgress() {
          await MainActor.run {
            guard byToken[token] != nil else { return }
            let phase = progress.phase.isEmpty ? nil : progress.phase
            let fraction: Double?
            if progress.active {
              if progress.bytesTotal > 0 {
                fraction = Double(progress.bytesDone) / Double(progress.bytesTotal)
              } else if progress.fraction > 0 {
                fraction = progress.fraction
              } else {
                fraction = nil
              }
            } else {
              fraction = nil
            }
            let detail: String?
            if progress.bytesTotal > 0 {
              detail = Self.formatByteProgress(done: progress.bytesDone, total: progress.bytesTotal)
            } else if !progress.message.isEmpty {
              detail = progress.message
            } else {
              detail = nil
            }
            onUpdate(token, progress.active ? phase : nil, fraction, detail)
          }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  func stopIoProgressPolling() {
    ioProgressPollTask?.cancel()
    ioProgressPollTask = nil
  }

  private static func formatByteProgress(done: UInt64, total: UInt64) -> String {
    func mb(_ value: UInt64) -> String {
      String(format: "%.1f MB", Double(value) / (1024.0 * 1024.0))
    }
    return "\(mb(done)) / \(mb(total))"
  }
}
