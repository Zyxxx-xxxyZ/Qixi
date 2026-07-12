import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct QixiUtilitySheetView<Host: QixiUtilitySheetHost>: View {
  let sheet: QixiUtilitySheet
  @ObservedObject var host: Host
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        switch sheet {
        case .camera:
          CameraRecognitionSheet(host: host)
        case .importGame:
          SGFImportSheet(host: host)
        case .sync:
          SyncSettingsSheet(host: host)
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
    .disabled(host.isBackendInteractionBlocked)
    .interactiveDismissDisabled(host.isBackendInteractionBlocked)
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
