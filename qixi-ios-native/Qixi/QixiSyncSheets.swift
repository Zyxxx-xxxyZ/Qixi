import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Archive (WPS-style):
/// - New/untitled: user chooses the filename, then create.
/// - Existing document: Save simply replaces package + companion `.sgf`.
/// Always writes both `.sgf` + `.qixi.png` (local + iCloud when available).
/// Sized for a fixed presentation height — no ScrollView.
struct ArchiveSettingsSheet<Host: QixiArchiveSheetHost & ObservableObject>: View {
  @ObservedObject var host: Host
  @State private var fileName: String = ""
  @State private var status: String = ""
  @State private var isWorking = false
  @State private var isFailed = false
  @State private var thumbnail: UIImage?

  private var isExistingDocument: Bool { host.hasExistingArchiveDocument }

  var body: some View {
    VStack(spacing: 12) {
      HStack(alignment: .top, spacing: 16) {
        thumbnailView

        VStack(alignment: .leading, spacing: 8) {
          Text(L10n.text(.archiveFileNameLabel))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(QixiColor.ink.opacity(0.75))

          if isExistingDocument {
            Text(host.currentArchiveDisplayName ?? host.defaultArchiveFileName())
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(QixiColor.ink)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(QixiColor.separator, lineWidth: 0.8)
              )
          } else {
            TextField(L10n.text(.archiveFileNamePlaceholder), text: $fileName)
              .textInputAutocapitalization(.never)
              .disableAutocorrection(true)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(QixiColor.separator, lineWidth: 0.8)
              )
          }

          Label(L10n.text(.archiveAlwaysBothHint), systemImage: "doc.on.doc")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(QixiColor.ink.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: 520)

      if !status.isEmpty {
        Text(status)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(isFailed ? QixiColor.warningRed : QixiColor.ink.opacity(0.8))
          .multilineTextAlignment(.center)
          .lineLimit(3)
          .frame(maxWidth: 480)
      }

      Button {
        performArchiveSave()
      } label: {
        Label(
          isWorking ? L10n.text(.hermesLoading) : L10n.text(.archiveSaveSync),
          systemImage: "square.and.arrow.down"
        )
        .frame(maxWidth: 320)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
      .disabled(isWorking || !canSave)

      Text(L10n.text(isExistingDocument ? .archiveHintExisting : .archiveHint))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(QixiColor.ink.opacity(0.62))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 480)
    }
    .padding(.horizontal, 22)
    .padding(.top, 8)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear {
      if fileName.isEmpty {
        fileName = host.defaultArchiveFileName()
      }
      thumbnail = host.boardThumbnailImage(pixelSize: 208)
    }
  }

  private var canSave: Bool {
    if host.isBackendInteractionBlocked { return false }
    if isExistingDocument { return true }
    return !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private var thumbnailView: some View {
    Group {
      if let thumbnail {
        Image(uiImage: thumbnail)
          .resizable()
          .interpolation(.high)
          .aspectRatio(1, contentMode: .fit)
          .frame(width: 104, height: 104)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(QixiColor.separator, lineWidth: 0.8)
          )
          .shadow(color: Color.black.opacity(0.08), radius: 4, y: 1)
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.secondary.opacity(0.12))
          .frame(width: 104, height: 104)
          .overlay(
            Image(systemName: "checkerboard.rectangle")
              .font(.system(size: 28, weight: .semibold))
              .foregroundStyle(Color.secondary)
          )
      }
    }
    .accessibilityLabel(L10n.text(.archiveThumbnailLabel))
  }

  private func performArchiveSave() {
    guard canSave, !isWorking else { return }
    isWorking = true
    isFailed = false
    status = L10n.text(.archiveExporting)
    let wasExisting = isExistingDocument
    // Existing → name ignored (replace). New → user-chosen name.
    let name = wasExisting
      ? (host.currentArchiveDisplayName ?? host.defaultArchiveFileName())
      : fileName
    Task {
      do {
        try await host.saveArchiveAndSync(fileName: name)
        status = L10n.text(wasExisting ? .archiveSyncReadyExisting : .archiveSyncReady)
        isFailed = false
        isWorking = false
      } catch {
        status = L10n.text(.archiveExportFailed)
        isFailed = true
        isWorking = false
      }
    }
  }
}

typealias SyncSettingsSheet = ArchiveSettingsSheet

// MARK: - Export & Share

struct ExportShareSheet<Host: QixiExportShareHost & ObservableObject>: View {
  @ObservedObject var host: Host
  @State private var status: String = ""
  @State private var isWorking = false
  @State private var isFailed = false
  @State private var exportDocument: QixiMultiURLExportDocument?
  @State private var sharePayload: QixiSharePayload?

  var body: some View {
    VStack(spacing: 14) {
      Text(L10n.text(.exportShareHint))
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(QixiColor.ink.opacity(0.72))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 440)

      Button {
        handleExportToFiles()
      } label: {
        Label(L10n.text(.exportSaveToFiles), systemImage: "folder")
          .frame(maxWidth: 340)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
      .disabled(isWorking || host.isBackendInteractionBlocked)

      Button {
        handleShare()
      } label: {
        Label(L10n.text(.exportShareAction), systemImage: "square.and.arrow.up")
          .frame(maxWidth: 340)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
      .disabled(isWorking || host.isBackendInteractionBlocked)

      if !status.isEmpty {
        Text(status)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(isFailed ? QixiColor.warningRed : QixiColor.ink.opacity(0.8))
          .multilineTextAlignment(.center)
          .lineLimit(3)
      }
    }
    .padding(.horizontal, 22)
    .padding(.top, 12)
    .padding(.bottom, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .sheet(item: $exportDocument) { document in
      QixiArchiveDocumentExporter(urls: document.urls) {
        Task { @MainActor in
          for url in document.urls {
            QixiImportedFileAccess.removeTemporaryCopy(url)
          }
          if exportDocument?.id == document.id {
            exportDocument = nil
          }
          status = L10n.text(.exportShareReady)
          isFailed = false
          isWorking = false
        }
      }
    }
    .sheet(item: $sharePayload) { payload in
      QixiActivityShareSheet(items: payload.items) {
        if sharePayload?.id == payload.id {
          sharePayload = nil
        }
        for url in payload.cleanupURLs {
          QixiImportedFileAccess.removeTemporaryCopy(url)
        }
        status = L10n.text(.exportShareReady)
        isWorking = false
      }
    }
  }

  private func handleExportToFiles() {
    guard !isWorking else { return }
    isWorking = true
    isFailed = false
    status = L10n.text(.exportSharePreparing)
    Task {
      do {
        let urls = try await host.prepareExportShareFiles()
        exportDocument = QixiMultiURLExportDocument(urls: urls)
      } catch {
        status = L10n.text(.exportShareFailed)
        isFailed = true
        isWorking = false
      }
    }
  }

  private func handleShare() {
    guard !isWorking else { return }
    isWorking = true
    isFailed = false
    status = L10n.text(.exportSharePreparing)
    Task {
      do {
        let urls = try await host.prepareExportShareFiles()
        sharePayload = QixiSharePayload(items: urls, cleanupURLs: urls)
      } catch {
        status = L10n.text(.exportShareFailed)
        isFailed = true
        isWorking = false
      }
    }
  }
}

// MARK: - Document exporter / share

private struct QixiMultiURLExportDocument: Identifiable {
  let id = UUID()
  var urls: [URL]
}

private struct QixiSharePayload: Identifiable {
  let id = UUID()
  var items: [Any]
  var cleanupURLs: [URL]
}

private struct QixiArchiveDocumentExporter: UIViewControllerRepresentable {
  var urls: [URL]
  var onFinished: () -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    private let parent: QixiArchiveDocumentExporter
    init(parent: QixiArchiveDocumentExporter) { self.parent = parent }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      parent.onFinished()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      parent.onFinished()
    }
  }
}

private struct QixiActivityShareSheet: UIViewControllerRepresentable {
  var items: [Any]
  var onFinished: () -> Void

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
    controller.completionWithItemsHandler = { _, _, _, _ in
      onFinished()
    }
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
