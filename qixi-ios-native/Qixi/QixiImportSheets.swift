import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Open sheet: one browse button + in-app list of `.qixi.png` archives (local + iCloud).
struct SGFImportSheet<Host: QixiOpenSheetHost & ObservableObject>: View {
  @ObservedObject var host: Host
  @State private var activeImporter: OpenImporterKind?
  @State private var status: String = ""
  @State private var visualState: ImportSheetVisualState = .idle
  @State private var items: [QixiArchiveListItem] = []
  @State private var thumbnails: [String: UIImage] = [:]
  @State private var isRefreshing = false

  var body: some View {
    VStack(spacing: 10) {
      // Single open control above the list (system picker for files outside the archive folders).
      Button {
        activeImporter = .anyArchive
      } label: {
        Label(L10n.text(.openChooseFile), systemImage: "folder.badge.plus")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
      .disabled(visualState == .verifying || host.isBackendInteractionBlocked)
      .padding(.horizontal, 4)

      if host.isBackendInteractionBlocked {
        Text(L10n.text(.openBusyHint))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(QixiColor.hermesOrange)
          .multilineTextAlignment(.center)
      }

      if !status.isEmpty {
        Text(status)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(visualState == .failed ? QixiColor.warningRed : QixiColor.ink.opacity(0.75))
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }

      // Smooth, lazy list of .qixi.png only.
      List {
        if items.isEmpty && !isRefreshing {
          Text(L10n.text(.openEmptyList))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(QixiColor.ink.opacity(0.55))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        ForEach(items) { item in
          Button {
            openListItem(item)
          } label: {
            HStack(spacing: 12) {
              thumbnailView(for: item)
              VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                  .font(.system(size: 15, weight: .semibold))
                  .foregroundStyle(QixiColor.ink)
                  .lineLimit(2)
                  .multilineTextAlignment(.leading)
                if item.isICloud {
                  Text(L10n.text(.openICloudBadge))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QixiColor.hermesBlue.opacity(0.9))
                }
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QixiColor.ink.opacity(0.35))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(visualState == .verifying)
          .listRowBackground(Color.white.opacity(0.55))
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { refreshList() }
    .fullScreenCover(item: $activeImporter) { kind in
      QixiDocumentOpenPicker(
        contentTypes: kind.contentTypes,
        onPicked: { result in
          activeImporter = nil
          handleBrowseResult(result)
        },
        onCancel: {
          activeImporter = nil
        }
      )
      .ignoresSafeArea()
    }
  }

  @ViewBuilder
  private func thumbnailView(for item: QixiArchiveListItem) -> some View {
    Group {
      if let image = thumbnails[item.id] {
        Image(uiImage: image)
          .resizable()
          .interpolation(.medium)
          .aspectRatio(1, contentMode: .fill)
      } else {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.secondary.opacity(0.12))
          .overlay(
            Image(systemName: "checkerboard.rectangle")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(Color.secondary)
          )
      }
    }
    .frame(width: 56, height: 56)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(QixiColor.separator, lineWidth: 0.7)
    )
  }

  private func refreshList() {
    isRefreshing = true
    let listed = host.listOpenableArchivePackages()
    items = listed
    isRefreshing = false
    // Load thumbnails off the critical path.
    Task.detached(priority: .utility) {
      var loaded: [String: UIImage] = [:]
      for item in listed.prefix(80) {
        if let image = QixiMCTSStatePackageStore.previewThumbnailImage(from: item.url, maxPixelSize: 128) {
          loaded[item.id] = image
        }
      }
      await MainActor.run {
        thumbnails.merge(loaded) { _, new in new }
      }
    }
  }

  private func openListItem(_ item: QixiArchiveListItem) {
    Task { @MainActor in
      if host.isBackendInteractionBlocked {
        status = L10n.text(.openBusyHint)
        visualState = .failed
        return
      }
      status = L10n.text(.openLoading)
      visualState = .verifying
      do {
        try await host.openArchiveListItem(item)
        status = L10n.text(.mctsStateImported)
        visualState = .installed
        refreshList()
      } catch {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        status = "\(L10n.text(.openFailed)): \(detail)"
        visualState = .failed
      }
    }
  }

  private func handleBrowseResult(_ result: Result<[URL], Error>) {
    Task { @MainActor in
      if host.isBackendInteractionBlocked {
        status = L10n.text(.openBusyHint)
        visualState = .failed
        return
      }
      var localCopyURL: URL?
      defer { QixiImportedFileAccess.removeTemporaryCopy(localCopyURL) }
      do {
        guard let url = try result.get().first else { return }
        status = L10n.text(.openLoading)
        visualState = .verifying
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".sgf") {
          let importedURL = try QixiImportedFileAccess.makeTemporaryLocalCopy(from: url)
          localCopyURL = importedURL
          let text = try QixiSGFParser.loadText(from: importedURL)
          try await host.openSGF(text: text)
          status = String(format: L10n.text(.importLoadedMoves), host.mainLineCount)
          visualState = .installed
        } else {
          let looksLikePackage =
            QixiImportedFileAccess.isMCTSPackageURL(url) ||
            QixiImportedFileAccess.isMCTSPackageURL(
              QixiImportedFileAccess.resolveMCTSPackageRootIfNeeded(url)
            ) ||
            QixiMCTSStatePackageStore.filenameLooksLikePackage(url.lastPathComponent)
          guard looksLikePackage else {
            status = L10n.text(.openFailed) + " (not a Qixi archive)"
            visualState = .failed
            return
          }
          let importedURL = try QixiImportedFileAccess.makeTemporaryLocalCopy(from: url)
          localCopyURL = importedURL
          try await host.openMCTSStatePackage(from: importedURL, originURL: url)
          status = L10n.text(.mctsStateImported)
          visualState = .installed
        }
        refreshList()
      } catch {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        status = "\(L10n.text(.openFailed)): \(detail)"
        visualState = .failed
      }
    }
  }
}

// MARK: - Picker kinds

private enum OpenImporterKind: String, Identifiable {
  case anyArchive
  var id: String { rawValue }

  var contentTypes: [UTType] {
    var types: [UTType] = [.data, .item, .content, .png, .image]
    if let sgf = UTType(filenameExtension: "sgf") {
      types.insert(sgf, at: 0)
    }
    return types
  }
}

private enum ImportSheetVisualState {
  case idle
  case verifying
  case failed
  case installed
}

// MARK: - UIKit document picker (reliable inside sheets)

struct QixiDocumentOpenPicker: UIViewControllerRepresentable {
  var contentTypes: [UTType]
  var onPicked: (Result<[URL], Error>) -> Void
  var onCancel: () -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
    picker.allowsMultipleSelection = false
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    private let parent: QixiDocumentOpenPicker
    init(parent: QixiDocumentOpenPicker) { self.parent = parent }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      parent.onPicked(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      parent.onCancel()
    }
  }
}
