import Foundation

/// Internal bookkeeping for long-running backend work (engine load, I/O, etc.).
/// Not shown as a main-page modal; product UI stays interactive without progress pop-ups.
struct QixiBlockingJob: Equatable, Identifiable {
  enum Kind: String, Equatable {
    case restoringState
    case switchingEngine
    case exportingState
    case importingState
    case installingModel
    case memoryUnload
    case memoryReload
  }

  /// What the main page must disable while the job runs.
  struct Blocks: OptionSet, Equatable {
    let rawValue: Int
    static let navigation = Blocks(rawValue: 1 << 0)
    static let engine = Blocks(rawValue: 1 << 1)
    static let io = Blocks(rawValue: 1 << 2)
    static let all: Blocks = [.navigation, .engine, .io]
  }

  let id: UInt64
  var kind: Kind
  var title: String
  var phase: String
  /// 0...1 when known; nil means indeterminate.
  var fraction: Double?
  var detail: String?
  var blocks: Blocks

  var isDeterminate: Bool { fraction != nil }

  static func title(for kind: Kind) -> String {
    switch kind {
    case .restoringState: return L10n.text(.backendRestoringState)
    case .switchingEngine: return L10n.text(.backendLoadingEngine)
    case .exportingState: return L10n.text(.mctsStateExporting)
    case .importingState: return L10n.text(.mctsStateImporting)
    case .installingModel: return L10n.text(.backendInstallingModel)
    case .memoryUnload: return L10n.text(.memoryPressureUnloading)
    case .memoryReload: return L10n.text(.memoryPressureReloading)
    }
  }

  static func blocks(for kind: Kind) -> Blocks {
    switch kind {
    case .exportingState:
      return [.io, .navigation]
    case .switchingEngine:
      // Never block the engine strip itself — user must be able to re-pick a model
      // while a prior load is in flight (supersede). Still pause board play / I/O.
      return [.navigation, .io]
    case .installingModel, .restoringState, .importingState, .memoryUnload, .memoryReload:
      return .all
    }
  }
}

@MainActor
final class QixiBlockingJobCoordinator: ObservableObject {
  @Published private(set) var activeJob: QixiBlockingJob?
  private var nextID: UInt64 = 1
  private var stack: [QixiBlockingJob] = []

  var isBlockingAll: Bool {
    activeJob?.blocks.contains(.all) == true || activeJob?.blocks == .all
  }

  var blocksNavigation: Bool {
    activeJob?.blocks.contains(.navigation) == true
  }

  var blocksEngine: Bool {
    activeJob?.blocks.contains(.engine) == true
  }

  var blocksIO: Bool {
    activeJob?.blocks.contains(.io) == true
  }

  @discardableResult
  func begin(
    _ kind: QixiBlockingJob.Kind,
    phase: String = "",
    fraction: Double? = nil,
    detail: String? = nil
  ) -> UInt64 {
    let id = nextID
    nextID &+= 1
    precondition(nextID != 0, "blocking job id overflow")
    let job = QixiBlockingJob(
      id: id,
      kind: kind,
      title: QixiBlockingJob.title(for: kind),
      phase: phase.isEmpty ? QixiBlockingJob.title(for: kind) : phase,
      fraction: fraction,
      detail: detail,
      blocks: QixiBlockingJob.blocks(for: kind)
    )
    stack.append(job)
    activeJob = job
    return id
  }

  func update(
    id: UInt64,
    phase: String? = nil,
    fraction: Double? = nil,
    detail: String? = nil
  ) {
    guard let index = stack.firstIndex(where: { $0.id == id }) else { return }
    if let phase { stack[index].phase = phase }
    if let fraction {
      stack[index].fraction = min(1.0, max(0.0, fraction))
    }
    if let detail { stack[index].detail = detail }
    if activeJob?.id == id {
      activeJob = stack[index]
    }
  }

  func finish(_ id: UInt64?) {
    guard let id else { return }
    stack.removeAll { $0.id == id }
    activeJob = stack.last
  }
}
