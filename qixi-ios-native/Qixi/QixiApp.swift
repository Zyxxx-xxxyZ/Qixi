import SwiftUI
import UIKit
import QuartzCore

@main
struct QixiApp: App {
  @StateObject private var model = QixiViewModel()

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .background(QixiFrameRatePreferenceView().frame(width: 0, height: 0))
        .statusBarHidden(true)
        .preferredColorScheme(.light)
    }
    // No background / terminate tombstone or foreground restore actions.
    // No autosave / auto-sync. MCTS checkpoint remains for OOM hard unload only.
  }
}

struct QixiFrameRatePreferenceView: UIViewRepresentable {
  func makeUIView(context: Context) -> QixiFrameRatePreferenceUIView {
    QixiFrameRatePreferenceUIView()
  }

  func updateUIView(_ uiView: QixiFrameRatePreferenceUIView, context: Context) {
    uiView.configureFrameRatePreferenceIfNeeded()
  }
}

final class QixiFrameRatePreferenceUIView: UIView {
  private var updateLink: AnyObject?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    isUserInteractionEnabled = false
    backgroundColor = .clear
  }

  deinit {
    releaseFrameRatePreference()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    configureFrameRatePreferenceIfNeeded()
  }

  func configureFrameRatePreferenceIfNeeded() {
    guard window != nil else {
      releaseFrameRatePreference()
      return
    }
    guard updateLink == nil else { return }
    if #available(iOS 18.0, *) {
      let link = UIUpdateLink(view: self)
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
      // UIUpdateLink is passive by default; do not force continuous updates while the board is idle.
      link.isEnabled = true
      updateLink = link
    }
  }

  private func releaseFrameRatePreference() {
    if #available(iOS 18.0, *), let link = updateLink as? UIUpdateLink {
      link.isEnabled = false
    }
    updateLink = nil
  }
}
