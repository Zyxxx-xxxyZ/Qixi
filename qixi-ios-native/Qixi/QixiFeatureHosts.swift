import Foundation
import SwiftUI
import UIKit

// MARK: - Board recognition (camera)

@MainActor
protocol QixiBoardRecognitionHost: AnyObject {
  var isBackendInteractionBlocked: Bool { get }
  var lastBoardRecognition: QixiBoardRecognitionResult? { get }
  /// Apply photographed setup stones. `nextPlayer` is who plays the next move at root.
  func applyBoardRecognition(_ result: QixiBoardRecognitionResult, nextPlayer: StoneColor)
}

// MARK: - Open

@MainActor
protocol QixiOpenSheetHost: AnyObject {
  var isBackendInteractionBlocked: Bool { get }
  var mainLineCount: Int { get }
  func openSGF(text: String) async throws
  func openMCTSStatePackage(from packageURL: URL, originURL: URL?) async throws
  /// In-app archive list (local + iCloud `.qixi.png`).
  func listOpenableArchivePackages() -> [QixiSyncStore.ArchiveListItem]
  /// Open a list item (may prompt for unsaved changes via host).
  func openArchiveListItem(_ item: QixiSyncStore.ArchiveListItem) async throws
}

// MARK: - Archive

struct QixiArchiveExportOptions: Equatable {
  var fileName: String
  var includeSGF: Bool
  var includeSearchState: Bool
}

@MainActor
protocol QixiArchiveSheetHost: AnyObject {
  var isBackendInteractionBlocked: Bool { get }
  /// Suggested name when creating a *new* document (WPS first save).
  func defaultArchiveFileName() -> String
  /// True when Save should replace the already-bound document (no rename step).
  var hasExistingArchiveDocument: Bool { get }
  /// Display name of the bound document, if any.
  var currentArchiveDisplayName: String? { get }
  func boardThumbnailImage(pixelSize: CGFloat) -> UIImage
  var hasArchivableSearchState: Bool { get }
  var hasArchivableGameRecord: Bool { get }
  /// Legacy exporter entry (tests / residual). Prefer `saveArchiveAndSync`.
  func prepareArchiveExport(options: QixiArchiveExportOptions) async throws -> URL
  /// WPS save: create with `fileName` when untitled; replace in place when a document is bound.
  /// Always writes both `.sgf` + `.qixi.png` (local + iCloud when available).
  func saveArchiveAndSync(fileName: String) async throws
}

// MARK: - Export & Share

@MainActor
protocol QixiExportShareHost: AnyObject {
  var isBackendInteractionBlocked: Bool { get }
  /// Temporary `.sgf` + `.qixi.png` for Files export / system share sheet.
  func prepareExportShareFiles() async throws -> [URL]
}

// MARK: - Sync (internal residual / automation)

@MainActor
protocol QixiSyncFeatureHost: AnyObject {
  /// True when the app will prefer the iCloud ubiquity container (availability / automation).
  /// Not a user-facing setting — iCloud file R/W needs no in-app authorization.
  var iCloudSyncEnabled: Bool { get }
  var syncStatus: QixiSyncStatus { get }
  var isBackendInteractionBlocked: Bool { get }
  var isAutomationSyncStatusPinned: Bool { get }
  var isUntouchedLaunchDefaultState: Bool { get }

  func buildAppSnapshot(reason: String) -> QixiAppSnapshot
  func applyImportedAppSnapshot(_ snapshot: QixiAppSnapshot)
  func resumeAnalysisAfterImportedSnapshot()
  func setICloudSyncEnabled(_ enabled: Bool)
  func notePersistenceError(_ message: String?)
  func noteSyncResult(_ result: QixiSyncResult)
  func noteSyncMirrorFailure(_ message: String)
  func mirrorVisibleMCTSStatePackageAfterManualSync(result: QixiSyncResult) async throws
  func cancelPendingPersistenceSave()
  func syncNow()
}

// MARK: - Utility sheet router host

@MainActor
protocol QixiUtilitySheetHost: QixiBoardRecognitionHost, QixiOpenSheetHost, QixiArchiveSheetHost, QixiExportShareHost, QixiSyncFeatureHost, ObservableObject {
  var isBackendInteractionBlocked: Bool { get }
}
