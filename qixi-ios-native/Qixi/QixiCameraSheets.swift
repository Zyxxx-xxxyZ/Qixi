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

struct CameraRecognitionSheet<Host: QixiBoardRecognitionHost & ObservableObject>: View {
  @ObservedObject var host: Host
  @State private var item: PhotosPickerItem?
  @State private var status = L10n.text(.cameraSheetIdle)
  @State private var isCameraPresented = false
  @State private var isRecognizing = false
  @State private var pendingBoardImage: QixiPendingBoardImage?
  @State private var pendingTemporaryPhotoURL: URL?
  @State private var isConsumingPendingPhoto = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "camera.metering.matrix")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(QixiColor.hermesBlue)
      if isRecognizing {
        ProgressView()
          .tint(QixiColor.hermesBlue)
      }
      Text(status)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(QixiColor.ink)
        .multilineTextAlignment(.center)
      Text(L10n.text(.cameraHistoryWarning))
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(QixiColor.muted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        Button {
          isCameraPresented = true
        } label: {
          Label(L10n.text(.utilityCamera), systemImage: "camera.viewfinder")
            .frame(maxWidth: 320)
        }
        .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
        .disabled(isRecognizing)
      }
      PhotosPicker(selection: $item, matching: .images) {
        Label(L10n.text(.cameraChoosePhoto), systemImage: "photo")
          .frame(maxWidth: 320)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
      .disabled(isRecognizing)
      .onChange(of: item) { _, item in
        guard let item else { return }
        preparePickedPhotoForSelection(item)
      }
      .fullScreenCover(isPresented: $isCameraPresented) {
        QixiCameraCaptureView { image in
          prepareCapturedImageForSelection(image)
        }
      }
      .fullScreenCover(item: $pendingBoardImage, onDismiss: {
        if !isConsumingPendingPhoto {
          cleanupPendingPhotoFile()
        }
      }) { pending in
        QixiBoardCropSelectionView(
          image: pending.image,
          initialSelection: pending.suggestedSelection,
          onCancel: {
            pendingBoardImage = nil
            cleanupPendingPhotoFile()
            status = L10n.text(.cameraSheetIdle)
          },
          onAutoLocate: {
            pending.suggestedSelection
          },
          onRecognize: { selection in
            isConsumingPendingPhoto = true
            pendingBoardImage = nil
            recognizePendingImage(pending, selection: selection)
          }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .onDisappear(perform: cleanupPendingPhotoFile)
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

  private func recognizePendingImage(_ pending: QixiPendingBoardImage, selection: QixiBoardImageSelection) {
    Task {
      setRecognizing(true)
      defer {
        setRecognizing(false)
        isConsumingPendingPhoto = false
        cleanupPendingPhotoFile()
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
        await finishRecognition(result)
      } catch {
        failRecognition(error)
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
    pendingBoardImage = pending
    status = L10n.text(.cameraSelectionHint)
  }

  @MainActor
  private func finishRecognition(_ result: QixiBoardRecognitionResult) async {
    host.applyBoardRecognition(result)
    let blackCount = result.stones.filter { $0.color == .black }.count
    let whiteCount = result.stones.filter { $0.color == .white }.count
    status = String(
      format: L10n.text(.cameraRecognizedStones),
      result.stones.count,
      blackCount,
      whiteCount
    )
    try? await Task.sleep(nanoseconds: 450_000_000)
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

private struct QixiBoardCropSelectionView: View {
  let image: UIImage
  let initialSelection: QixiBoardImageSelection
  var onCancel: () -> Void
  var onAutoLocate: () -> QixiBoardImageSelection?
  var onRecognize: (QixiBoardImageSelection) -> Void
  @State private var selection: QixiBoardImageSelection

  init(
    image: UIImage,
    initialSelection: QixiBoardImageSelection,
    onCancel: @escaping () -> Void,
    onAutoLocate: @escaping () -> QixiBoardImageSelection?,
    onRecognize: @escaping (QixiBoardImageSelection) -> Void
  ) {
    self.image = image
    self.initialSelection = initialSelection
    self.onCancel = onCancel
    self.onAutoLocate = onAutoLocate
    self.onRecognize = onRecognize
    _selection = State(initialValue: initialSelection)
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
        Button(L10n.text(.cameraAutoSelection)) {
          selection = (onAutoLocate() ?? initialSelection).clamped()
        }
        .buttonStyle(.bordered)
        Button(L10n.text(.cameraRecognizeSelection)) {
          onRecognize(selection.clamped())
        }
        .buttonStyle(.borderedProminent)
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

