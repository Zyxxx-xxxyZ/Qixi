import SwiftUI

// MARK: - Sample data for layout previews (simulator gallery)

enum CameraRecognitionReviewSample {
  static let result: QixiBoardRecognitionResult = {
    // Sparse but readable mid-game shape for visual review.
    var stones: [RecognizedBoardStone] = []
    let black: [(Int, Int)] = [
      (3, 3), (15, 3), (3, 15), (15, 15), (2, 5), (5, 2), (16, 4), (4, 16),
      (9, 3), (3, 9), (15, 9), (9, 15), (6, 6), (12, 6), (6, 12), (12, 12),
      (8, 4), (10, 4), (4, 8), (4, 10), (14, 8), (14, 10), (8, 14), (10, 14),
      (7, 9), (11, 9), (9, 7), (9, 11)
    ]
    let white: [(Int, Int)] = [
      (2, 3), (3, 2), (16, 3), (15, 2), (3, 16), (2, 15), (15, 16), (16, 15),
      (5, 3), (3, 5), (13, 3), (15, 5), (3, 13), (5, 15), (13, 15), (15, 13),
      (8, 6), (10, 6), (6, 8), (6, 10), (12, 8), (12, 10), (8, 12), (10, 12),
      (9, 9), (7, 7), (11, 7), (7, 11), (11, 11)
    ]
    for (x, y) in black {
      stones.append(RecognizedBoardStone(x: x, y: y, color: .black, confidence: 0.9))
    }
    for (x, y) in white {
      stones.append(RecognizedBoardStone(x: x, y: y, color: .white, confidence: 0.9))
    }
    return QixiBoardRecognitionResult(
      stones: stones,
      gridX: (0..<19).map { Double($0) },
      gridY: (0..<19).map { Double($0) }
    )
  }()
}

// MARK: - Layout catalog (segmented Black|White locked; vary everything else)

/// Round-2 aesthetics: every layout uses iOS `.segmented` for side-to-move.
/// Only chrome / CTA placement / proportions differ.
enum CameraRecognitionReviewLayoutID: String, CaseIterable, Identifiable {
  case segEqualCTA
  case segApplyDominant
  case segStackedActions
  case segFloatingDock
  case segCardFooter
  case segInlineSplit

  var id: String { rawValue }

  var title: String {
    switch self {
    case .segEqualCTA: return "S1 · Segmented + equal CTAs"
    case .segApplyDominant: return "S2 · Apply-dominant row"
    case .segStackedActions: return "S3 · Segmented + stacked actions"
    case .segFloatingDock: return "S4 · Floating dock"
    case .segCardFooter: return "S5 · Segmented in card footer"
    case .segInlineSplit: return "S6 · Segmented left · actions right"
    }
  }

  var blurb: String {
    switch self {
    case .segEqualCTA:
      return "Confirmed B|W segmented control; equal-width Discard + Apply"
    case .segApplyDominant:
      return "Segmented full width; wide Apply with compact Discard beside it"
    case .segStackedActions:
      return "Segmented full width; full-width Apply then Discard underneath"
    case .segFloatingDock:
      return "Board-forward; material dock with segmented + dual CTAs"
    case .segCardFooter:
      return "Elevated footer card wrapping segmented + actions"
    case .segInlineSplit:
      return "Segmented (left ~58%) with Apply/Discard stack (right rail)"
    }
  }

  static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CameraRecognitionReviewLayoutID? {
    guard let raw = environment["QIXI_REVIEW_LAYOUT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else { return nil }
    if let byName = CameraRecognitionReviewLayoutID(rawValue: raw) { return byName }
    if let index = Int(raw), CameraRecognitionReviewLayoutID.allCases.indices.contains(index) {
      return CameraRecognitionReviewLayoutID.allCases[index]
    }
    // S1…S6 and 1…6 aliases
    let map: [String: CameraRecognitionReviewLayoutID] = [
      "S1": .segEqualCTA, "1": .segEqualCTA, "A": .segEqualCTA,
      "S2": .segApplyDominant, "2": .segApplyDominant, "B": .segApplyDominant,
      "S3": .segStackedActions, "3": .segStackedActions, "C": .segStackedActions,
      "S4": .segFloatingDock, "4": .segFloatingDock, "D": .segFloatingDock,
      "S5": .segCardFooter, "5": .segCardFooter, "E": .segCardFooter,
      "S6": .segInlineSplit, "6": .segInlineSplit, "F": .segInlineSplit
    ]
    return map[raw.uppercased()]
  }
}

// MARK: - Gallery host (simulator aesthetics review)

/// Full-screen gallery of recognition-review layout variants for aesthetic comparison.
struct CameraRecognitionReviewLayoutGallery: View {
  @State private var nextPlayer: StoneColor = .white
  @State private var page: Int

  init(initial: CameraRecognitionReviewLayoutID = .segEqualCTA) {
    let idx = CameraRecognitionReviewLayoutID.allCases.firstIndex(of: initial) ?? 0
    _page = State(initialValue: idx)
  }

  var body: some View {
    let layouts = CameraRecognitionReviewLayoutID.allCases
    ZStack {
      Color.black.opacity(0.45).ignoresSafeArea()
      VStack(spacing: 0) {
        // Chrome
        HStack {
          Text("Review layout gallery")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(QixiColor.ink)
          Spacer()
          Text("\(page + 1)/\(layouts.count)")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(QixiColor.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(QixiColor.background)

        TabView(selection: $page) {
          ForEach(Array(layouts.enumerated()), id: \.element.id) { index, layout in
            VStack(spacing: 0) {
              VStack(alignment: .leading, spacing: 4) {
                Text(layout.title)
                  .font(.system(size: 17, weight: .bold))
                  .foregroundStyle(QixiColor.ink)
                Text(layout.blurb)
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(QixiColor.muted)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 18)
              .padding(.vertical, 10)
              .background(QixiColor.background.opacity(0.95))

              CameraRecognitionReviewLayoutChrome(
                layout: layout,
                result: CameraRecognitionReviewSample.result,
                nextPlayer: $nextPlayer,
                onRetryCorners: {},
                onDiscard: {},
                onApply: { _ in }
              )
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .stroke(QixiColor.separatorStrong, lineWidth: 0.8)
              )
              .padding(.horizontal, 16)
              .padding(.bottom, 16)
              .frame(maxWidth: 520)
              .frame(maxWidth: .infinity)
            }
            .tag(index)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(QixiColor.background)
      }
      .frame(maxWidth: 560)
      .frame(maxHeight: 780)
      .background(QixiColor.background)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 16)
      .padding(24)
    }
    .accessibilityIdentifier("camera-recognition-review-layout-gallery")
  }
}

/// Single full-screen layout preview (for automated screenshots via QIXI_REVIEW_LAYOUT).
struct CameraRecognitionReviewLayoutSolo: View {
  let layout: CameraRecognitionReviewLayoutID
  @State private var nextPlayer: StoneColor = .white

  var body: some View {
    ZStack {
      Color.black.opacity(0.35).ignoresSafeArea()
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(layout.title)
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(QixiColor.ink)
            Text(layout.blurb)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(QixiColor.muted)
              .lineLimit(2)
          }
          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(QixiColor.background)

        CameraRecognitionReviewLayoutChrome(
          layout: layout,
          result: CameraRecognitionReviewSample.result,
          nextPlayer: $nextPlayer,
          onRetryCorners: {},
          onDiscard: {},
          onApply: { _ in }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: 480)
      .frame(maxHeight: 720)
      .background(QixiColor.background)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .shadow(color: .black.opacity(0.2), radius: 24, x: 0, y: 14)
      .padding(20)
    }
    .accessibilityIdentifier("camera-recognition-review-layout-solo-\(layout.rawValue)")
  }
}

// MARK: - Shared chrome + layout bodies

struct CameraRecognitionReviewLayoutChrome: View {
  let layout: CameraRecognitionReviewLayoutID
  let result: QixiBoardRecognitionResult
  @Binding var nextPlayer: StoneColor
  var onRetryCorners: () -> Void
  var onDiscard: () -> Void
  var onApply: (StoneColor) -> Void

  private var blackCount: Int { result.stones.filter { $0.color == .black }.count }
  private var whiteCount: Int { result.stones.filter { $0.color == .white }.count }

  var body: some View {
    NavigationStack {
      Group {
        switch layout {
        case .segEqualCTA:
          layoutSegEqualCTA
        case .segApplyDominant:
          layoutSegApplyDominant
        case .segStackedActions:
          layoutSegStackedActions
        case .segFloatingDock:
          layoutSegFloatingDock
        case .segCardFooter:
          layoutSegCardFooter
        case .segInlineSplit:
          layoutSegInlineSplit
        }
      }
      .background(QixiColor.background)
      .navigationTitle(L10n.text(.cameraSheetTitle))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.text(.cameraRetryCorners), action: onRetryCorners)
        }
      }
    }
  }

  private var summaryText: some View {
    Text(
      String(
        format: L10n.text(.cameraRecognizedStones),
        result.stones.count,
        blackCount,
        whiteCount
      )
    )
    .font(.system(size: 15, weight: .semibold))
    .foregroundStyle(QixiColor.ink)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var board: some View {
    CameraRecognitionMiniBoard(stones: result.stones)
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .layoutPriority(1)
  }

  /// Locked side control for this round.
  private func segmentedSide(height: CGFloat = 34) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.text(.cameraNextPlayerLabel))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(QixiColor.muted)
      Picker("", selection: $nextPlayer) {
        Text(L10n.text(.cameraNextPlayerBlack)).tag(StoneColor.black)
        Text(L10n.text(.cameraNextPlayerWhite)).tag(StoneColor.white)
      }
      .pickerStyle(.segmented)
      .frame(height: height)
      .labelsHidden()
    }
  }

  // S1 · Segmented + equal CTAs
  private var layoutSegEqualCTA: some View {
    VStack(spacing: 14) {
      summaryText
      board
      segmentedSide(height: 34)
      HStack(spacing: 10) {
        discardButton(height: 44)
        applyButton(height: 44)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 16)
  }

  // S2 · Apply-dominant row (Discard compact)
  private var layoutSegApplyDominant: some View {
    VStack(spacing: 12) {
      summaryText
      board
      segmentedSide(height: 36)
      HStack(spacing: 10) {
        discardButton(height: 44)
          .frame(maxWidth: 108)
        applyButton(height: 44)
      }
    }
    .padding(.horizontal, 18)
    .padding(.top, 6)
    .padding(.bottom, 14)
  }

  // S3 · Stacked actions under segmented
  private var layoutSegStackedActions: some View {
    VStack(spacing: 11) {
      summaryText
      board
      segmentedSide(height: 34)
      applyButton(height: 46)
      discardButton(height: 38)
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 14)
  }

  // S4 · Floating material dock
  private var layoutSegFloatingDock: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 10) {
        summaryText
        board
        Spacer(minLength: 96)
      }
      .padding(.horizontal, 18)
      .padding(.top, 6)

      VStack(spacing: 10) {
        segmentedSide(height: 32)
        HStack(spacing: 10) {
          discardButton(height: 40)
          applyButton(height: 40)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(QixiColor.separatorStrong.opacity(0.85), lineWidth: 0.7)
      )
      .padding(.horizontal, 14)
      .padding(.bottom, 12)
    }
  }

  // S5 · Elevated card footer
  private var layoutSegCardFooter: some View {
    VStack(spacing: 0) {
      summaryText
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
      board
        .padding(.horizontal, 18)
      VStack(spacing: 12) {
        segmentedSide(height: 34)
        HStack(spacing: 10) {
          discardButton(height: 42)
          applyButton(height: 42)
        }
      }
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.white.opacity(0.58))
          .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(QixiColor.separator.opacity(0.85), lineWidth: 0.8)
      )
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 16)
    }
  }

  // S6 · Segmented left, actions right (product hybrid with confirmed control)
  private var layoutSegInlineSplit: some View {
    VStack(spacing: 12) {
      summaryText
      board
      HStack(alignment: .bottom, spacing: 14) {
        segmentedSide(height: 36)
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)
        VStack(spacing: 8) {
          applyButton(height: 44)
          discardButton(height: 36)
        }
        .frame(width: 120)
      }
      .padding(.top, 2)
    }
    .padding(.horizontal, 18)
    .padding(.top, 6)
    .padding(.bottom, 14)
  }

  // MARK: Shared controls

  private func applyButton(height: CGFloat) -> some View {
    Button {
      onApply(nextPlayer)
    } label: {
      Text(L10n.text(.cameraApplyRecognition))
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(QixiColor.ink)
        )
    }
    .buttonStyle(.plain)
  }

  private func discardButton(height: CGFloat) -> some View {
    Button(action: onDiscard) {
      Text(L10n.text(.cameraDiscardRecognition))
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(QixiColor.muted)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.45))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(QixiColor.separator.opacity(0.9), lineWidth: 0.8)
        )
    }
    .buttonStyle(.plain)
  }
}
