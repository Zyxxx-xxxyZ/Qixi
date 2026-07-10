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

private enum QixiImportedFileAccess {
  static func makeTemporaryLocalCopy(from pickedURL: URL) throws -> URL {
    let scoped = pickedURL.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        pickedURL.stopAccessingSecurityScopedResource()
      }
    }

    requestUbiquitousDownloadIfNeeded(for: pickedURL)

    var coordinatedResult: Result<URL, Error>?
    var coordinationError: NSError?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(readingItemAt: pickedURL, options: [], error: &coordinationError) { readableURL in
      coordinatedResult = Result {
        let temporaryURL = temporaryCopyURL(for: readableURL)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
          try FileManager.default.removeItem(at: temporaryURL)
        }
        try FileManager.default.copyItem(at: readableURL, to: temporaryURL)
        return temporaryURL
      }
    }

    if let coordinatedResult {
      return try coordinatedResult.get()
    }
    throw coordinationError ?? CocoaError(.fileReadUnknown)
  }

  static func removeTemporaryCopy(_ url: URL?) {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private static func requestUbiquitousDownloadIfNeeded(for url: URL) {
    let values = try? url.resourceValues(forKeys: [
      .isUbiquitousItemKey,
      .ubiquitousItemDownloadingStatusKey
    ])
    guard values?.isUbiquitousItem == true else { return }
    if values?.ubiquitousItemDownloadingStatus != .current {
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
  }

  private static func temporaryCopyURL(for readableURL: URL) -> URL {
    let filename = readableURL.lastPathComponent.isEmpty ? "imported-file" : readableURL.lastPathComponent
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("qixi-import-\(UUID().uuidString)-\(filename)", isDirectory: isDirectory(readableURL))
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}

struct QixiUtilitySheetView: View {
  let sheet: QixiUtilitySheet
  @ObservedObject var model: QixiViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        switch sheet {
        case .camera:
          CameraRecognitionSheet(model: model)
        case .importGame:
          SGFImportSheet(model: model)
        case .sync:
          SyncSettingsSheet(model: model)
        }
      }
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.text(.sheetDone)) {
            dismiss()
          }
        }
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .background(QixiColor.background)
    }
    .disabled(model.isBackendInteractionBlocked)
    .interactiveDismissDisabled(model.isBackendInteractionBlocked)
    .accessibilityIdentifier("qixi-utility-sheet-\(sheet.rawValue)")
  }

  private var title: String {
    switch sheet {
    case .camera: return L10n.text(.cameraSheetTitle)
    case .importGame: return L10n.text(.importSheetTitle)
    case .sync: return L10n.text(.syncSheetTitle)
    }
  }
}

private struct CameraRecognitionSheet: View {
  @ObservedObject var model: QixiViewModel
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
    model.applyBoardRecognition(result)
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

private struct QixiExportedMCTSStatePackage: Identifiable {
  let id = UUID()
  var url: URL
}

private struct QixiDocumentExporter: UIViewControllerRepresentable {
  var url: URL
  var onFinished: () -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    private let parent: QixiDocumentExporter

    init(parent: QixiDocumentExporter) {
      self.parent = parent
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      parent.onFinished()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      parent.onFinished()
    }
  }
}

private struct SGFImportSheet: View {
  @ObservedObject var model: QixiViewModel
  @State private var isSGFImporterPresented = false
  @State private var isMCTSStateImporterPresented = false
  @State private var exportedMCTSStatePackage: QixiExportedMCTSStatePackage?
  @State private var status: String
  @State private var visualState: ImportSheetVisualState

  init(model: QixiViewModel) {
    self.model = model
    _status = State(initialValue: Self.initialStatus(environment: ProcessInfo.processInfo.environment))
    _visualState = State(initialValue: Self.initialVisualState(environment: ProcessInfo.processInfo.environment))
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: visualState.systemImageName)
        .font(.system(size: 38, weight: .semibold))
        .foregroundStyle(visualState.tint)
      Text(status)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(QixiColor.ink)
        .multilineTextAlignment(.center)
      Button {
        isSGFImporterPresented = true
      } label: {
        Label(L10n.text(.importChooseSGF), systemImage: "doc.badge.arrow.up")
          .frame(maxWidth: 320)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))

      Button {
        isMCTSStateImporterPresented = true
      } label: {
        Label(L10n.text(.importChooseMCTSState), systemImage: "archivebox")
          .frame(maxWidth: 320)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))

      Button {
        handleMCTSStateExport()
      } label: {
        Label(L10n.text(.exportMCTSState), systemImage: "square.and.arrow.up")
          .frame(maxWidth: 320)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
      .disabled(visualState == .verifying)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .fileImporter(
      isPresented: $isSGFImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "sgf") ?? .plainText, .plainText, .data, .item],
      allowsMultipleSelection: false
    ) { result in
      var localCopyURL: URL?
      defer {
        QixiImportedFileAccess.removeTemporaryCopy(localCopyURL)
      }
      do {
        guard let url = try result.get().first else { return }
        let importedURL = try QixiImportedFileAccess.makeTemporaryLocalCopy(from: url)
        localCopyURL = importedURL
        let text = try QixiSGFParser.loadText(from: importedURL)
        try model.importSGF(text: text)
        status = String(format: L10n.text(.importLoadedMoves), model.mainLine.count)
        visualState = .installed
      } catch {
        status = L10n.text(.importFailed)
        visualState = .failed
      }
    }
    .fileImporter(
      isPresented: $isMCTSStateImporterPresented,
      allowedContentTypes: mctsStateAllowedContentTypes,
      allowsMultipleSelection: false
    ) { result in
      handleMCTSStateImportResult(result)
    }
    .sheet(item: $exportedMCTSStatePackage) { package in
      mctsStateExportSheet(for: package)
    }
  }

  private var mctsStateAllowedContentTypes: [UTType] {
    [
      UTType(QixiMCTSStatePackageStore.contentTypeIdentifier) ?? .package,
      UTType(filenameExtension: QixiMCTSStatePackageStore.packageExtension) ?? .package,
      .package,
      .item
    ]
  }

  private func mctsStateExportSheet(for package: QixiExportedMCTSStatePackage) -> some View {
    QixiDocumentExporter(url: package.url) {
      Task { @MainActor in
        QixiImportedFileAccess.removeTemporaryCopy(package.url)
        if exportedMCTSStatePackage?.id == package.id {
          exportedMCTSStatePackage = nil
        }
        status = L10n.text(.mctsStateExportReady)
        visualState = .installed
      }
    }
  }

  private func handleMCTSStateImportResult(_ result: Result<[URL], Error>) {
    Task {
      var localCopyURL: URL?
      defer {
        QixiImportedFileAccess.removeTemporaryCopy(localCopyURL)
      }
      do {
        guard let url = try result.get().first else { return }
        let importedURL = try QixiImportedFileAccess.makeTemporaryLocalCopy(from: url)
        localCopyURL = importedURL
        status = L10n.text(.mctsStateImporting)
        visualState = .verifying
        try await model.importMCTSStatePackage(from: importedURL)
        status = L10n.text(.mctsStateImported)
        visualState = .installed
      } catch {
        status = L10n.text(.mctsStateImportFailed)
        visualState = .failed
      }
    }
  }

  private func handleMCTSStateExport() {
    Task {
      do {
        status = L10n.text(.mctsStateExporting)
        visualState = .verifying
        let packageURL = try await model.prepareMCTSStateExportPackage()
        exportedMCTSStatePackage = QixiExportedMCTSStatePackage(url: packageURL)
      } catch {
        status = L10n.text(.mctsStateExportFailed)
        visualState = .failed
      }
    }
  }

  private static func initialStatus(environment: [String: String]) -> String {
    guard let rawValue = environment["QIXI_IMPORT_SHEET_STATUS"] else {
      return L10n.text(.importSheetIdle)
    }
    switch normalizedImportStatus(rawValue) {
    case "idle":
      return L10n.text(.importSheetIdle)
    case "verifying":
      return L10n.text(.mctsStateImporting)
    case "failed":
      return L10n.text(.mctsStateImportFailed)
    case "installed":
      return L10n.text(.mctsStateImported)
    default:
      return L10n.text(.importSheetIdle)
    }
  }

  private static func initialVisualState(environment: [String: String]) -> ImportSheetVisualState {
    guard let rawValue = environment["QIXI_IMPORT_SHEET_STATUS"] else {
      return .idle
    }
    switch normalizedImportStatus(rawValue) {
    case "verifying":
      return .verifying
    case "failed":
      return .failed
    case "installed":
      return .installed
    default:
      return .idle
    }
  }

  private static func normalizedImportStatus(_ rawValue: String) -> String {
    rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
  }
}

private enum ImportSheetVisualState {
  case idle
  case verifying
  case installed
  case failed

  var systemImageName: String {
    switch self {
    case .idle:
      return "doc.badge.arrow.up"
    case .verifying:
      return "hourglass"
    case .installed:
      return "checkmark.seal.fill"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .idle:
      return QixiColor.hermesBlue
    case .verifying:
      return QixiColor.hermesOrange
    case .installed:
      return QixiColor.successGreen
    case .failed:
      return QixiColor.warningRed
    }
  }
}

private struct SyncSettingsSheet: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: model.iCloudSyncEnabled ? "icloud.and.arrow.up" : "icloud.slash")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(model.iCloudSyncEnabled ? QixiColor.hermesBlue : Color.secondary)
      Text(model.iCloudSyncEnabled ? L10n.text(.syncEnabled) : L10n.text(.syncDisabled))
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(QixiColor.ink)
      if let lastSyncAt = model.syncStatus.lastSyncAt {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(QixiColor.successGreen)
          Text(
            String(
              format: L10n.text(.syncLastSynced),
              lastSyncAt.formatted(date: .abbreviated, time: .shortened)
            )
          )
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(QixiColor.ink)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(12)
        .background(QixiColor.successGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(QixiColor.successGreen.opacity(0.30), lineWidth: 0.8)
        )
      }
      if let lastError = model.syncStatus.lastError {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(QixiColor.warningRed)
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(.syncErrorTitle))
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(QixiColor.warningRed)
            Text(lastError)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(QixiColor.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(12)
        .background(QixiColor.warningRed.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(QixiColor.warningRed.opacity(0.28), lineWidth: 0.8)
        )
      }
      Button {
        model.syncNow()
      } label: {
        Label(L10n.text(.syncNow), systemImage: "arrow.triangle.2.circlepath")
          .frame(maxWidth: 320)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}
