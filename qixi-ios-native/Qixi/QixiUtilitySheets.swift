import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct QixiUtilitySheetView<Host: QixiUtilitySheetHost>: View {
  let sheet: QixiUtilitySheet
  @ObservedObject var host: Host

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
        case .exportShare:
          ExportShareSheet(host: host)
        }
      }
      // No Done control — dismiss by swipe/drag. Title is principal + bold (large-title weight
      // without the large-title vertical layout that misaligned with a trailing button).
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text(title)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(QixiColor.ink)
            .accessibilityAddTraits(.isHeader)
        }
      }
      // Content-fitting heights so camera/archive never rely on scrolling.
      // Import stays medium/large (shorter action list).
      .presentationDetents(presentationDetents)
      .presentationDragIndicator(.visible)
      .background(QixiColor.background)
    }
    .accessibilityIdentifier("qixi-utility-sheet-\(sheet.rawValue)")
  }

  private var title: String {
    switch sheet {
    case .camera: return L10n.text(.cameraSheetTitle)
    case .importGame: return L10n.text(.openSheetTitle)
    case .sync: return L10n.text(.archiveSheetTitle)
    case .exportShare: return L10n.text(.exportShareSheetTitle)
    }
  }

  private var presentationDetents: Set<PresentationDetent> {
    switch sheet {
    case .camera:
      return [.height(360), .large]
    case .sync:
      // Compact archive form — no scroll.
      return [.height(340)]
    case .exportShare:
      return [.height(280)]
    case .importGame:
      // List needs vertical space; medium/large only (list scrolls, chrome does not).
      return [.medium, .large]
    }
  }
}
