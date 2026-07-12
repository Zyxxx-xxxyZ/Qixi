import Foundation
import SwiftUI

/// Long-running work that may block parts of the main-page interaction.
/// Designed for product-path core I/O (reload, export, engine load) with progress.
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
    case .memoryUnload: return L10n.text(.backendRestoringState)
    case .memoryReload: return L10n.text(.backendRestoringState)
    }
  }

  static func blocks(for kind: Kind) -> Blocks {
    switch kind {
    case .exportingState:
      return [.io, .navigation]
    case .switchingEngine, .installingModel, .restoringState, .importingState, .memoryUnload, .memoryReload:
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

/// Main-page progress chrome. Matches the paper / Hermes visual language without
/// redesigning the analysis workbench layout.
struct QixiMainPageProgressChrome: View {
  let job: QixiBlockingJob

  var body: some View {
    ZStack {
      QixiColor.background.opacity(0.92).ignoresSafeArea()
      VStack(spacing: 18) {
        Text(L10n.text(.onboardingTitle))
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(QixiColor.ink)
        Text(job.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(QixiColor.ink)
          .multilineTextAlignment(.center)
        Group {
          if let fraction = job.fraction {
            ProgressView(value: fraction)
              .tint(QixiColor.hermesBlue)
              .frame(maxWidth: 280)
          } else {
            ProgressView()
              .controlSize(.large)
              .tint(QixiColor.hermesBlue)
          }
        }
        .accessibilityLabel(job.phase)
        Text(job.phase)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(QixiColor.muted)
          .multilineTextAlignment(.center)
        if let detail = job.detail, !detail.isEmpty {
          Text(detail)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(QixiColor.muted.opacity(0.9))
            .multilineTextAlignment(.center)
        }
      }
      .padding(28)
      .frame(maxWidth: 420)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(QixiColor.separatorStrong, lineWidth: 0.8)
      )
      .shadow(color: .black.opacity(0.12), radius: 28, x: 0, y: 18)
      .padding(.horizontal, 22)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("qixi-blocking-job-progress")
  }
}
