import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct QixiPickedBoardPhoto: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      let sourceURL = received.file
      let destinationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("qixi-picked-board-photo-\(UUID().uuidString)")
        .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "image" : sourceURL.pathExtension)
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      return QixiPickedBoardPhoto(url: destinationURL)
    }
  }

  func removeTemporaryFile() {
    try? FileManager.default.removeItem(at: url)
  }
}

private struct QixiPendingBoardImage: Identifiable {
  enum Source {
    case data(Data)
    case file(URL)
  }

  let id = UUID()
  var image: UIImage
  var source: Source
  var suggestedSelection: QixiBoardImageSelection
}

private enum QixiPendingBoardImageFactory {
  static func make(from data: Data) throws -> QixiPendingBoardImage {
    try QixiBoardImageRecognizer.validatePendingSelectionImageDataForUI(data)
    guard let image = UIImage(data: data)?.qixiNormalizedForBoardSelection() else {
      throw QixiBoardImageRecognizer.RecognitionError.unreadableImage
    }
    let selection = (try? QixiBoardImageRecognizer.suggestedSelection(from: data)) ?? .defaultGrid
    return QixiPendingBoardImage(image: image, source: .data(data), suggestedSelection: selection)
  }

  static func make(from url: URL) throws -> QixiPendingBoardImage {
    let preview = try QixiBoardImageRecognizer.selectionPreviewImage(from: url)
    let selection = (try? QixiBoardImageRecognizer.suggestedSelection(from: url)) ?? .defaultGrid
    return QixiPendingBoardImage(
      image: UIImage(cgImage: preview),
      source: .file(url),
      suggestedSelection: selection
    )
  }
}

/// Recognition succeeded — user reviews stones, then chooses who moves next and applies.
private struct QixiPendingRecognitionReview: Identifiable {
  let id = UUID()
  var result: QixiBoardRecognitionResult
  /// Suggested side-to-move from stone counts (user may override).
  var suggestedNextPlayer: StoneColor
}

struct CameraRecognitionSheet<Host: QixiBoardRecognitionHost & ObservableObject>: View {
  @ObservedObject var host: Host
  @State private var item: PhotosPickerItem?
  @State private var status = L10n.text(.cameraSheetIdle)
  @State private var isCameraPresented = false
  @State private var isRecognizing = false
  @State private var pendingBoardImage: QixiPendingBoardImage?
  @State private var pendingTemporaryPhotoURL: URL?
  /// True while crop is dismissed only to run recognition (keep temp photo for Retry).
  @State private var isConsumingPendingPhoto = false
  /// Same photo kept after scan so Retry can re-open four-corner crop (not retake).
  @State private var retryPendingImage: QixiPendingBoardImage?
  @State private var lastCropSelection: QixiBoardImageSelection?
  /// Post-recognition review (stones already demonstrated; next-player chosen here).
  @State private var pendingReview: QixiPendingRecognitionReview?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    // Scroll only if needed so a short sheet never clips Choose Photo.
    ScrollView {
      VStack(spacing: 10) {
        Image(systemName: "camera.metering.matrix")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(QixiColor.hermesBlue)
        if isRecognizing {
          ProgressView()
            .tint(QixiColor.hermesBlue)
        }
        Text(status)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(QixiColor.ink)
          .multilineTextAlignment(.center)
        // Status (选择棋盘照片) stays above the actions; full warning moves under Choose Photo.

        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button {
            isCameraPresented = true
          } label: {
            Label(L10n.text(.utilityCamera), systemImage: "camera.viewfinder")
              .frame(maxWidth: 320)
          }
          .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
          .disabled(isRecognizing || pendingReview != nil)
        }
        PhotosPicker(selection: $item, matching: .images) {
          Label(L10n.text(.cameraChoosePhoto), systemImage: "photo")
            .frame(maxWidth: 320)
        }
        .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
        .disabled(isRecognizing || pendingReview != nil)
        .onChange(of: item) { _, item in
          guard let item else { return }
          preparePickedPhotoForSelection(item)
        }
        Text(L10n.text(.cameraHistoryWarning))
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(QixiColor.muted)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 420)
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.top, 8)
      .padding(.bottom, 8)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // Attach covers to the sheet root so crop UI is not nested under PhotosPicker only.
    .fullScreenCover(isPresented: $isCameraPresented) {
      QixiCameraCaptureView { image in
        prepareCapturedImageForSelection(image)
      }
    }
    .fullScreenCover(item: $pendingBoardImage, onDismiss: {
      // Only wipe the photo when the user cancels crop entirely — not when scanning
      // (isConsumingPendingPhoto) or when Retry will re-open the same image.
      if !isConsumingPendingPhoto, pendingReview == nil, retryPendingImage == nil {
        cleanupPendingPhotoFile()
      }
    }) { pending in
      QixiBoardCropSelectionView(
        image: pending.image,
        initialSelection: pending.suggestedSelection,
        onCancel: {
          pendingBoardImage = nil
          retryPendingImage = nil
          lastCropSelection = nil
          cleanupPendingPhotoFile()
          status = L10n.text(.cameraSheetIdle)
        },
        onRecognize: { selection in
          isConsumingPendingPhoto = true
          retryPendingImage = pending
          lastCropSelection = selection
          pendingBoardImage = nil
          recognizePendingImage(pending, selection: selection)
        }
      )
    }
    .sheet(item: $pendingReview) { review in
      CameraRecognitionReviewSheet(
        result: review.result,
        suggestedNextPlayer: review.suggestedNextPlayer,
        onRetryCorners: {
          retryCornerSelection()
        },
        onDiscard: {
          discardRecognitionReview()
        },
        onApply: { nextPlayer in
          applyReviewedRecognition(review.result, nextPlayer: nextPlayer)
        }
      )
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
      .interactiveDismissDisabled()
    }
    .onDisappear {
      // Sheet closed entirely — safe to drop the temp photo.
      retryPendingImage = nil
      lastCropSelection = nil
      cleanupPendingPhotoFile()
    }
  }

  private func preparePickedPhotoForSelection(_ item: PhotosPickerItem) {
    Task {
      setRecognizing(true)
      defer { setRecognizing(false) }
      do {
        guard let photo = try await item.loadTransferable(type: QixiPickedBoardPhoto.self) else { return }
        let pending: QixiPendingBoardImage
        do {
          pending = try await Task.detached(priority: .userInitiated) {
            try QixiPendingBoardImageFactory.make(from: photo.url)
          }.value
        } catch {
          photo.removeTemporaryFile()
          throw error
        }
        pendingTemporaryPhotoURL = photo.url
        presentPendingImage(pending)
      } catch {
        failRecognition(error)
      }
    }
  }

  private func prepareCapturedImageForSelection(_ image: UIImage) {
    Task {
      setRecognizing(true)
      defer { setRecognizing(false) }
      do {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
          failRecognition()
          return
        }
        let pending = try await Task.detached(priority: .userInitiated) {
          try QixiPendingBoardImageFactory.make(from: data)
        }.value
        presentPendingImage(pending)
      } catch {
        failRecognition(error)
      }
    }
  }

  private func recognizePendingImage(
    _ pending: QixiPendingBoardImage,
    selection: QixiBoardImageSelection
  ) {
    Task {
      setRecognizing(true)
      defer {
        setRecognizing(false)
        isConsumingPendingPhoto = false
        // Keep temp photo / retryPendingImage for "Adjust corners" Retry.
      }
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          switch pending.source {
          case .data(let data):
            return try QixiBoardImageRecognizer.recognizeBoard(from: data, selection: selection)
          case .file(let url):
            return try QixiBoardImageRecognizer.recognizeBoard(from: url, selection: selection)
          }
        }.value
        await presentRecognitionReview(result)
      } catch {
        // Recognition failed — still allow Retry to re-crop the same photo.
        await MainActor.run {
          failRecognition(error)
          retryCornerSelection()
        }
      }
    }
  }

  @MainActor
  private func setRecognizing(_ value: Bool) {
    isRecognizing = value
    if value {
      status = L10n.text(.cameraImageLoaded)
    }
  }

  @MainActor
  private func presentPendingImage(_ pending: QixiPendingBoardImage) {
    retryPendingImage = nil
    lastCropSelection = nil
    pendingBoardImage = pending
    status = L10n.text(.cameraSelectionHint)
  }

  /// Show recognized stones first; next-player choice happens only on the review step.
  @MainActor
  private func presentRecognitionReview(_ result: QixiBoardRecognitionResult) {
    let blackCount = result.stones.filter { $0.color == .black }.count
    let whiteCount = result.stones.filter { $0.color == .white }.count
    status = String(
      format: L10n.text(.cameraRecognizedStones),
      result.stones.count,
      blackCount,
      whiteCount
    )
    pendingReview = QixiPendingRecognitionReview(
      result: result,
      suggestedNextPlayer: Self.suggestedNextPlayer(blackCount: blackCount, whiteCount: whiteCount)
    )
  }

  /// Even counts → Black; Black one ahead (typical after Black just played) → White; else Black.
  private static func suggestedNextPlayer(blackCount: Int, whiteCount: Int) -> StoneColor {
    if blackCount == whiteCount + 1 { return .white }
    return .black
  }

  /// Retry = re-open four-corner crop for the **same** photo (not retake / re-pick).
  @MainActor
  private func retryCornerSelection() {
    pendingReview = nil
    guard let retry = retryPendingImage else {
      status = L10n.text(.cameraSheetIdle)
      return
    }
    let selection = lastCropSelection ?? retry.suggestedSelection
    // New Identifiable instance so fullScreenCover re-presents reliably.
    pendingBoardImage = QixiPendingBoardImage(
      image: retry.image,
      source: retry.source,
      suggestedSelection: selection
    )
    status = L10n.text(.cameraSelectionHint)
  }

  /// Discard = abandon the recognition result; stay on camera sheet (no apply, no re-crop).
  @MainActor
  private func discardRecognitionReview() {
    pendingReview = nil
    retryPendingImage = nil
    lastCropSelection = nil
    pendingBoardImage = nil
    item = nil
    cleanupPendingPhotoFile()
    status = L10n.text(.cameraSheetIdle)
  }

  @MainActor
  private func applyReviewedRecognition(_ result: QixiBoardRecognitionResult, nextPlayer: StoneColor) {
    host.applyBoardRecognition(result, nextPlayer: nextPlayer)
    pendingReview = nil
    retryPendingImage = nil
    lastCropSelection = nil
    cleanupPendingPhotoFile()
    dismiss()
  }

  @MainActor
  private func failRecognition(_ error: Error? = nil) {
    if let message = error?.localizedDescription, !message.isEmpty {
      status = "\(L10n.text(.cameraRecognitionFailed)): \(message)"
    } else {
      status = L10n.text(.cameraRecognitionFailed)
    }
  }

  @MainActor
  private func cleanupPendingPhotoFile() {
    guard let url = pendingTemporaryPhotoURL else { return }
    pendingTemporaryPhotoURL = nil
    try? FileManager.default.removeItem(at: url)
  }
}

/// Shown only after recognition demonstrates stones — never before scan.
/// Fits without scrolling: board flexes to remaining height.
private struct CameraRecognitionReviewSheet: View {
  let result: QixiBoardRecognitionResult
  let suggestedNextPlayer: StoneColor
  /// Re-open four-corner crop for the same image.
  var onRetryCorners: () -> Void
  /// Abandon result; return to camera sheet without applying.
  var onDiscard: () -> Void
  var onApply: (StoneColor) -> Void
  @State private var nextPlayer: StoneColor

  init(
    result: QixiBoardRecognitionResult,
    suggestedNextPlayer: StoneColor,
    onRetryCorners: @escaping () -> Void,
    onDiscard: @escaping () -> Void,
    onApply: @escaping (StoneColor) -> Void
  ) {
    self.result = result
    self.suggestedNextPlayer = suggestedNextPlayer
    self.onRetryCorners = onRetryCorners
    self.onDiscard = onDiscard
    self.onApply = onApply
    _nextPlayer = State(initialValue: suggestedNextPlayer)
  }

  private var blackCount: Int { result.stones.filter { $0.color == .black }.count }
  private var whiteCount: Int { result.stones.filter { $0.color == .white }.count }

  /// S5 card-footer proportions.
  private static let actionHeight: CGFloat = 42
  private static let segmentedHeight: CGFloat = 34

  var body: some View {
    // Product layout = gallery S5 (segmented in elevated card footer).
    // Discard has no inner edge/border (text + soft fill only).
    NavigationStack {
      VStack(spacing: 0) {
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
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityIdentifier("camera-recognition-result-summary")

        CameraRecognitionMiniBoard(stones: result.stones)
          .aspectRatio(1, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .layoutPriority(1)
          .padding(.horizontal, 18)
          .accessibilityIdentifier("camera-recognition-result-board")

        VStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(.cameraNextPlayerLabel))
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(QixiColor.muted)
              .accessibilityIdentifier("camera-next-player-label")
            Picker(L10n.text(.cameraNextPlayerLabel), selection: $nextPlayer) {
              Text(L10n.text(.cameraNextPlayerBlack)).tag(StoneColor.black)
              Text(L10n.text(.cameraNextPlayerWhite)).tag(StoneColor.white)
            }
            .pickerStyle(.segmented)
            .frame(height: Self.segmentedHeight)
            .accessibilityIdentifier("camera-next-player-picker")
          }

          HStack(spacing: 10) {
            // No stroke — soft secondary only (blue edge reserved for selection).
            Button {
              onDiscard()
            } label: {
              Text(L10n.text(.cameraDiscardRecognition))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(QixiColor.muted)
                .frame(maxWidth: .infinity)
                .frame(height: Self.actionHeight)
                .background(
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.40))
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("camera-discard-recognition")

            // Primary action — ink fill, not blue.
            Button {
              onApply(nextPlayer)
            } label: {
              Text(L10n.text(.cameraApplyRecognition))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: Self.actionHeight)
                .background(
                  RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(QixiColor.ink)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("camera-apply-recognition")
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
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(QixiColor.background)
      .navigationTitle(L10n.text(.cameraSheetTitle))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.text(.cameraRetryCorners)) {
            onRetryCorners()
          }
          .accessibilityIdentifier("camera-retry-corners")
        }
      }
    }
    .accessibilityIdentifier("camera-recognition-review-sheet")
  }
}

/// Compact 19×19 board showing recognized stones for review.
struct CameraRecognitionMiniBoard: View {
  let stones: [RecognizedBoardStone]

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let origin = CGPoint(
        x: (proxy.size.width - side) * 0.5,
        y: (proxy.size.height - side) * 0.5
      )
      Canvas { context, _ in
        let boardRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        context.fill(Path(roundedRect: boardRect, cornerRadius: side * 0.02), with: .color(QixiColor.background))
        context.stroke(
          Path(roundedRect: boardRect, cornerRadius: side * 0.02),
          with: .color(QixiColor.separatorStrong),
          lineWidth: 1
        )
        let pad = side * 0.06
        let grid = side - pad * 2
        let step = grid / 18.0
        var lines = Path()
        for i in 0..<19 {
          let o = pad + CGFloat(i) * step
          lines.move(to: CGPoint(x: origin.x + pad, y: origin.y + o))
          lines.addLine(to: CGPoint(x: origin.x + pad + grid, y: origin.y + o))
          lines.move(to: CGPoint(x: origin.x + o, y: origin.y + pad))
          lines.addLine(to: CGPoint(x: origin.x + o, y: origin.y + pad + grid))
        }
        context.stroke(lines, with: .color(QixiColor.separatorStrong.opacity(0.85)), lineWidth: 0.8)
        let radius = step * 0.42
        for stone in stones {
          let cx = origin.x + pad + CGFloat(stone.x) * step
          let cy = origin.y + pad + CGFloat(stone.y) * step
          let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
          let path = Path(ellipseIn: rect)
          if stone.color == .black {
            context.fill(path, with: .color(.black.opacity(0.92)))
          } else {
            context.fill(path, with: .color(.white))
            context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 1)
          }
        }
      }
    }
  }
}

/// Black / White control — only used after recognition results are shown.
struct CameraNextPlayerChooser: View {
  enum Layout {
    /// Label above a dual-button row (default card).
    case stacked
    /// Footer-inline: compact dual segment matching Apply height on the right.
    case footerInline
  }

  @Binding var nextPlayer: StoneColor
  var layout: Layout = .stacked
  var primaryHeight: CGFloat = 44
  /// Legacy flag kept for call sites; maps to tighter stacked chrome.
  var compact: Bool = false

  private var effectiveLayout: Layout {
    if layout == .footerInline { return .footerInline }
    return .stacked
  }

  var body: some View {
    switch effectiveLayout {
    case .footerInline:
      footerInlineBody
    case .stacked:
      stackedBody
    }
  }

  private var footerInlineBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L10n.text(.cameraNextPlayerLabel))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(QixiColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("camera-next-player-label")
      HStack(spacing: 8) {
        nextPlayerButton(
          color: .black,
          title: L10n.text(.cameraNextPlayerBlack),
          fill: Color.black,
          height: primaryHeight,
          stoneSize: 16,
          fontSize: 15,
          cornerRadius: 11
        )
        nextPlayerButton(
          color: .white,
          title: L10n.text(.cameraNextPlayerWhite),
          fill: Color.white,
          height: primaryHeight,
          stoneSize: 16,
          fontSize: 15,
          cornerRadius: 11
        )
      }
    }
    .accessibilityIdentifier("camera-next-player-picker")
  }

  private var stackedBody: some View {
    let tight = compact
    return VStack(alignment: .leading, spacing: tight ? 8 : 10) {
      Text(L10n.text(.cameraNextPlayerLabel))
        .font(.system(size: tight ? 14 : 15, weight: .bold))
        .foregroundStyle(QixiColor.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("camera-next-player-label")
      HStack(spacing: 12) {
        nextPlayerButton(
          color: .black,
          title: L10n.text(.cameraNextPlayerBlack),
          fill: Color.black,
          height: tight ? 44 : 52,
          stoneSize: tight ? 18 : 22,
          fontSize: tight ? 16 : 17,
          cornerRadius: 12
        )
        nextPlayerButton(
          color: .white,
          title: L10n.text(.cameraNextPlayerWhite),
          fill: Color.white,
          height: tight ? 44 : 52,
          stoneSize: tight ? 18 : 22,
          fontSize: tight ? 16 : 17,
          cornerRadius: 12
        )
      }
    }
    .padding(tight ? 10 : 14)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(QixiColor.controlSurface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(QixiColor.separatorStrong, lineWidth: 1)
    )
    .accessibilityIdentifier("camera-next-player-picker")
  }

  private func nextPlayerButton(
    color: StoneColor,
    title: String,
    fill: Color,
    height: CGFloat,
    stoneSize: CGFloat,
    fontSize: CGFloat,
    cornerRadius: CGFloat
  ) -> some View {
    let selected = nextPlayer == color
    return Button {
      nextPlayer = color
    } label: {
      HStack(spacing: 8) {
        Circle()
          .fill(fill)
          .overlay(Circle().stroke(Color.black.opacity(0.28), lineWidth: 1))
          .frame(width: stoneSize, height: stoneSize)
        Text(title)
          .font(.system(size: fontSize, weight: .bold))
          .foregroundStyle(selected ? QixiColor.hermesBlue : QixiColor.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(selected ? QixiColor.hermesBlue.opacity(0.14) : Color.white.opacity(0.62))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(
            selected ? QixiColor.hermesBlue.opacity(0.9) : QixiColor.separator,
            lineWidth: selected ? 1.6 : 0.8
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(color == .black ? "camera-next-player-black" : "camera-next-player-white")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct QixiBoardCropSelectionView: View {
  let image: UIImage
  let initialSelection: QixiBoardImageSelection
  var onCancel: () -> Void
  var onRecognize: (QixiBoardImageSelection) -> Void
  @State private var selection: QixiBoardImageSelection

  init(
    image: UIImage,
    initialSelection: QixiBoardImageSelection,
    onCancel: @escaping () -> Void,
    onRecognize: @escaping (QixiBoardImageSelection) -> Void
  ) {
    self.image = image
    self.initialSelection = initialSelection
    self.onCancel = onCancel
    self.onRecognize = onRecognize
    // Start from automatic positioning; user may still drag corners if needed.
    _selection = State(initialValue: initialSelection.clamped())
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Button(L10n.text(.cameraCancelSelection)) {
          onCancel()
        }
        .buttonStyle(.bordered)
        Spacer(minLength: 12)
        Text(L10n.text(.cameraSelectionHint))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .multilineTextAlignment(.center)
        Spacer(minLength: 12)
        Button(L10n.text(.cameraRecognizeSelection)) {
          onRecognize(selection.clamped())
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("camera-recognize-selection")
      }
      .tint(QixiColor.hermesBlue)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .background(Color.black.opacity(0.92))

      GeometryReader { proxy in
        let imageFrame = fittedImageFrame(in: proxy.size)
        ZStack {
          Color.black.ignoresSafeArea()
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: proxy.size.width, height: proxy.size.height)
          selectionOverlay(in: imageFrame)
        }
        .coordinateSpace(name: "qixi-board-crop")
      }
    }
    .background(Color.black)
  }

  private func selectionOverlay(in imageFrame: CGRect) -> some View {
    ZStack {
      Path { path in
        let topLeft = displayPoint(selection.topLeft, in: imageFrame)
        let topRight = displayPoint(selection.topRight, in: imageFrame)
        let bottomRight = displayPoint(selection.bottomRight, in: imageFrame)
        let bottomLeft = displayPoint(selection.bottomLeft, in: imageFrame)
        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addLine(to: bottomRight)
        path.addLine(to: bottomLeft)
        path.closeSubpath()

        for index in 1..<18 {
          let u = CGFloat(index) / 18.0
          path.move(to: interpolateDisplayPoint(u: u, v: 0.0, in: imageFrame))
          path.addLine(to: interpolateDisplayPoint(u: u, v: 1.0, in: imageFrame))
          path.move(to: interpolateDisplayPoint(u: 0.0, v: u, in: imageFrame))
          path.addLine(to: interpolateDisplayPoint(u: 1.0, v: u, in: imageFrame))
        }
      }
      .stroke(.white.opacity(0.76), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

      ForEach(BoardCropCorner.allCases) { corner in
        cropHandle(for: corner, in: imageFrame)
      }
    }
  }

  private func cropHandle(for corner: BoardCropCorner, in imageFrame: CGRect) -> some View {
    Circle()
      .fill(QixiColor.hermesBlue)
      .frame(width: 30, height: 30)
      .overlay(Circle().stroke(.white, lineWidth: 3))
      .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 2)
      .position(displayPoint(selection.point(for: corner), in: imageFrame))
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named("qixi-board-crop"))
          .onChanged { value in
            selection.setPoint(normalizedPoint(value.location, in: imageFrame), for: corner)
          }
      )
      .accessibilityLabel(corner.accessibilityLabel)
  }

  private func fittedImageFrame(in containerSize: CGSize) -> CGRect {
    guard image.size.width > 0, image.size.height > 0 else {
      return CGRect(origin: .zero, size: containerSize)
    }
    let scale = min(containerSize.width / image.size.width, containerSize.height / image.size.height)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return CGRect(
      x: (containerSize.width - size.width) / 2.0,
      y: (containerSize.height - size.height) / 2.0,
      width: size.width,
      height: size.height
    )
  }

  private func displayPoint(_ point: CGPoint, in imageFrame: CGRect) -> CGPoint {
    CGPoint(
      x: imageFrame.minX + min(1.0, max(0.0, point.x)) * imageFrame.width,
      y: imageFrame.minY + min(1.0, max(0.0, point.y)) * imageFrame.height
    )
  }

  private func normalizedPoint(_ point: CGPoint, in imageFrame: CGRect) -> CGPoint {
    guard imageFrame.width > 0, imageFrame.height > 0 else { return .zero }
    return CGPoint(
      x: min(1.0, max(0.0, (point.x - imageFrame.minX) / imageFrame.width)),
      y: min(1.0, max(0.0, (point.y - imageFrame.minY) / imageFrame.height))
    )
  }

  private func interpolateDisplayPoint(u: CGFloat, v: CGFloat, in imageFrame: CGRect) -> CGPoint {
    let topLeft = displayPoint(selection.topLeft, in: imageFrame)
    let topRight = displayPoint(selection.topRight, in: imageFrame)
    let bottomRight = displayPoint(selection.bottomRight, in: imageFrame)
    let bottomLeft = displayPoint(selection.bottomLeft, in: imageFrame)
    let top = lerp(topLeft, topRight, u)
    let bottom = lerp(bottomLeft, bottomRight, u)
    return lerp(top, bottom, v)
  }

  private func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(
      x: lhs.x * (1.0 - t) + rhs.x * t,
      y: lhs.y * (1.0 - t) + rhs.y * t
    )
  }
}

private enum BoardCropCorner: CaseIterable, Identifiable {
  case topLeft
  case topRight
  case bottomRight
  case bottomLeft

  var id: String {
    switch self {
    case .topLeft: return "top-left"
    case .topRight: return "top-right"
    case .bottomRight: return "bottom-right"
    case .bottomLeft: return "bottom-left"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .topLeft: return "top left"
    case .topRight: return "top right"
    case .bottomRight: return "bottom right"
    case .bottomLeft: return "bottom left"
    }
  }
}

private extension QixiBoardImageSelection {
  func point(for corner: BoardCropCorner) -> CGPoint {
    switch corner {
    case .topLeft: return topLeft
    case .topRight: return topRight
    case .bottomRight: return bottomRight
    case .bottomLeft: return bottomLeft
    }
  }

  mutating func setPoint(_ point: CGPoint, for corner: BoardCropCorner) {
    switch corner {
    case .topLeft:
      topLeft = point
    case .topRight:
      topRight = point
    case .bottomRight:
      bottomRight = point
    case .bottomLeft:
      bottomLeft = point
    }
  }
}

private extension UIImage {
  func qixiNormalizedForBoardSelection(maxDimension: CGFloat = 1800.0) -> UIImage? {
    let targetScale = min(1.0, maxDimension / max(size.width, size.height))
    let targetSize = CGSize(width: size.width * targetScale, height: size.height * targetScale)
    guard targetSize.width > 0, targetSize.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: targetSize))
    }
  }
}

private struct QixiCameraCaptureView: UIViewControllerRepresentable {
  var onImage: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.cameraCaptureMode = .photo
    picker.allowsEditing = false
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let parent: QixiCameraCaptureView

    init(parent: QixiCameraCaptureView) {
      self.parent = parent
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage {
        parent.dismiss()
        DispatchQueue.main.async {
          self.parent.onImage(image)
        }
        return
      }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}

