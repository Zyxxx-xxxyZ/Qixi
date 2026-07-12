import Foundation
import SwiftUI

// MARK: - Board recognition (camera)

@MainActor
protocol QixiBoardRecognitionHost: AnyObject {
  var isBackendInteractionBlocked: Bool { get }
  var lastBoardRecognition: QixiBoardRecognitionResult? { get }
  func applyBoardRecognition(_ result: QixiBoardRecognitionResult)
}

// MARK: - SGF import

@MainActor
protocol QixiSGFImportHost: AnyObject {
  var isBackendInteractionBlocked: Bool { get }
  /// Move count after import (for status formatting).
  var mainLineCount: Int { get }
  func importSGF(text: String) throws
}

// MARK: - MCTS package (import sheet)

@MainActor
protocol QixiMCTSPackageHost: AnyObject {
  var isBackendInteractionBlocked: Bool { get }
  func prepareMCTSStateExportPackage() async throws -> URL
  func importMCTSStatePackage(from packageURL: URL) async throws
}

/// Combined host for the import utility sheet (SGF + MCTS package).
@MainActor
protocol QixiImportSheetHost: QixiSGFImportHost, QixiMCTSPackageHost {}

// MARK: - Sync UI + manual sync

@MainActor
protocol QixiSyncFeatureHost: AnyObject {
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
  /// Manual Sync Now (UI / onboarding).
  func syncNow()
}

// MARK: - Utility sheet router host

@MainActor
protocol QixiUtilitySheetHost: QixiBoardRecognitionHost, QixiImportSheetHost, QixiSyncFeatureHost, ObservableObject {
  var isBackendInteractionBlocked: Bool { get }
}
