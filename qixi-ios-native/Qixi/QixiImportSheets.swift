import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

struct SGFImportSheet<Host: QixiImportSheetHost & ObservableObject>: View {
  @ObservedObject var host: Host
  @State private var isSGFImporterPresented = false
  @State private var isMCTSStateImporterPresented = false
  @State private var exportedMCTSStatePackage: QixiExportedMCTSStatePackage?
  @State private var status: String
  @State private var visualState: ImportSheetVisualState

  init(host: Host) {
    self.host = host
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
        try host.importSGF(text: text)
        status = String(format: L10n.text(.importLoadedMoves), host.mainLineCount)
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
        try await host.importMCTSStatePackage(from: importedURL)
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
        let packageURL = try await host.prepareMCTSStateExportPackage()
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

