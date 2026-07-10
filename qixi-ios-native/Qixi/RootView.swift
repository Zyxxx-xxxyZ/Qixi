import SwiftUI

struct RootView: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    GeometryReader { proxy in
      let safeInsets = proxy.safeAreaInsets
      let contentWidth = max(1, proxy.size.width - safeInsets.leading - safeInsets.trailing)
      let contentHeight = max(1, proxy.size.height - safeInsets.top - safeInsets.bottom)
      ZStack {
        QixiColor.background.ignoresSafeArea()
        Group {
          if contentWidth >= contentHeight {
            let paneWidth = (contentWidth - 1.0) / 2.0
            HStack(spacing: 0) {
              LeftAnalysisPane(model: model)
                .frame(width: paneWidth)
              CenterDivider()
              RightBoardPane(model: model)
                .frame(width: paneWidth)
            }
          } else {
            VStack(spacing: 0) {
              RightBoardPane(model: model)
                .frame(height: contentHeight * 0.58)
              HorizontalDivider()
              LeftAnalysisPane(model: model)
            }
          }
        }
        .frame(width: contentWidth, height: contentHeight)
        .padding(.leading, safeInsets.leading)
        .padding(.trailing, safeInsets.trailing)
        .padding(.top, safeInsets.top)
        .padding(.bottom, safeInsets.bottom)
        .disabled(model.isBackendInteractionBlocked)

        if let transition = model.backendTransition, model.onboardingCompleted {
          BackendTransitionView(transition: transition)
            .transition(.opacity)
            .zIndex(3)
        }

        if !model.onboardingCompleted {
          OnboardingView(model: model)
            .transition(.opacity)
            .zIndex(4)
        }
      }
      .animation(.easeInOut(duration: 0.18), value: model.onboardingCompleted)
      .animation(.easeInOut(duration: 0.12), value: model.backendTransition)
    }
    .sheet(item: $model.utilitySheet) { sheet in
      QixiUtilitySheetView(sheet: sheet, model: model)
    }
  }
}

private struct BackendTransitionView: View {
  let transition: QixiBackendTransition

  var body: some View {
    ZStack {
      QixiColor.background.ignoresSafeArea()
      VStack(spacing: 22) {
        Text(L10n.text(.onboardingTitle))
          .font(.system(size: 36, weight: .bold))
          .foregroundStyle(QixiColor.ink)
        ProgressView()
          .controlSize(.large)
          .tint(QixiColor.hermesBlue)
          .accessibilityLabel(transition.statusText)
        Text(transition.statusText)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(QixiColor.muted)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 28)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("qixi-backend-transition")
  }
}

struct OnboardingView: View {
  @ObservedObject var model: QixiViewModel
  @State private var enableICloud = false

  var body: some View {
    ZStack {
      QixiColor.background.opacity(0.92).ignoresSafeArea()
      VStack(spacing: 18) {
        VStack(spacing: 6) {
          Text(L10n.text(.onboardingTitle))
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(QixiColor.ink)
          Text(L10n.text(.onboardingSubtitle))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(QixiColor.muted)
            .multilineTextAlignment(.center)
        }

        VStack(alignment: .leading, spacing: 10) {
          Text(L10n.text(.onboardingLanguageTitle))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(QixiColor.muted)
          HStack(spacing: 8) {
            ForEach(AppLanguage.allCases, id: \.rawValue) { language in
              Button {
                model.setLanguage(language)
              } label: {
                Text(L10n.languageName(language))
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(QixiSegmentButtonStyle(isSelected: model.language == language))
            }
          }
        }

        VStack(alignment: .leading, spacing: 8) {
          Toggle(isOn: $enableICloud) {
            VStack(alignment: .leading, spacing: 3) {
              Text(L10n.text(.onboardingICloudTitle))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(QixiColor.ink)
              Text(L10n.text(.onboardingICloudSubtitle))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(QixiColor.muted)
            }
          }
          .toggleStyle(.switch)
        }
        .padding(12)
        .background(QixiColor.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(QixiColor.separator, lineWidth: 0.8))

        HStack(spacing: 10) {
          Button {
            model.skipICloudOnboarding()
          } label: {
            Text(L10n.text(.onboardingSkipICloud))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(QixiCapsuleButtonStyle())

          Button {
            model.completeOnboarding(enableICloud: enableICloud)
          } label: {
            Label(
              enableICloud ? L10n.text(.onboardingEnableICloud) : L10n.text(.onboardingContinue),
              systemImage: enableICloud ? "icloud.and.arrow.up" : "arrow.right"
            )
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(QixiCapsuleButtonStyle(isSelected: true))
        }
      }
      .padding(22)
      .frame(maxWidth: 520)
      .padding(.horizontal, 22)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(QixiColor.separatorStrong, lineWidth: 0.8))
      .shadow(color: .black.opacity(0.12), radius: 28, x: 0, y: 18)
    }
  }
}

struct CenterDivider: View {
  var body: some View {
    Rectangle()
      .fill(
        LinearGradient(
          colors: [.clear, QixiColor.separator, QixiColor.separatorStrong, QixiColor.separator, .clear],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .frame(width: 1)
      .padding(.vertical, 18)
      .accessibilityHidden(true)
  }
}

struct HorizontalDivider: View {
  var body: some View {
    Rectangle()
      .fill(
        LinearGradient(
          colors: [.clear, QixiColor.separator, QixiColor.separatorStrong, QixiColor.separator, .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

struct RightBoardPane: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    GeometryReader { proxy in
      let hasEngineError = model.lastEngineError != nil
      let horizontalInset = min(26, max(14, proxy.size.width * 0.06))
      let topContentWidth = max(1, proxy.size.width - horizontalInset * 2)
      let topHeight: CGFloat = hasEngineError ? 92 : 58
      let verticalReserve: CGFloat = hasEngineError ? 164 : 130
      let boardSide = min(proxy.size.width * 0.86, max(240, proxy.size.height - verticalReserve))
      VStack(spacing: 0) {
        HStack {
          Spacer()
          VStack(alignment: .trailing, spacing: 6) {
            HermesStatusBadge(status: model.hermesStatus)
            if let lastEngineError = model.lastEngineError {
              EngineErrorBanner(message: lastEngineError)
            }
          }
          .frame(maxWidth: topContentWidth, alignment: .trailing)
        }
        .frame(height: topHeight)
        .padding(.horizontal, horizontalInset)

        Spacer(minLength: 8)

        BoardView(model: model)
          .frame(width: boardSide, height: boardSide)

        Spacer(minLength: 10)

        BoardControlStrip(model: model)
          .frame(height: 60)
          .padding(.horizontal, 26)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct HermesStatusBadge: View {
  var status: HermesStatus

  var body: some View {
    HStack(spacing: 8) {
      BundleImage(name: "hermesGatewayPulse")
        .aspectRatio(contentMode: .fit)
        .frame(width: 25, height: 25)
        .blendMode(.multiply)
      Circle()
        .fill(status.color)
        .frame(width: 8, height: 8)
      Text(status.title)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(status.color)
        .contentTransition(.numericText())
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 10)
    .background(QixiColor.controlSurface, in: Capsule(style: .continuous))
    .overlay(Capsule(style: .continuous).stroke(QixiColor.separator, lineWidth: 0.8))
    .accessibilityElement(children: .combine)
  }
}

struct EngineErrorBanner: View {
  var message: String

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(QixiColor.warningRed)
      VStack(alignment: .leading, spacing: 1) {
        Text(L10n.text(.engineErrorTitle))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(QixiColor.warningRed)
        Text(message)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(QixiColor.ink)
          .lineLimit(2)
          .minimumScaleFactor(0.78)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .frame(maxWidth: 360, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .background(QixiColor.warningRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(QixiColor.warningRed.opacity(0.26), lineWidth: 0.8)
    )
    .accessibilityElement(children: .combine)
  }
}

struct BoardControlStrip: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    HStack(spacing: 10) {
      Button {
        model.passMove()
      } label: {
        Label(L10n.text(.boardPass), systemImage: "hand.raised")
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(QixiCapsuleButtonStyle())

      Spacer(minLength: 18)

      RepeatControlButton(systemName: "gobackward.5", interval: 0.18) {
        model.step(by: -5)
      }
      RepeatControlButton(systemName: "chevron.left", interval: 0.30) {
        model.step(by: -1)
      }
      RepeatControlButton(systemName: "chevron.right", interval: 0.30) {
        model.step(by: 1)
      }
      RepeatControlButton(systemName: "goforward.5", interval: 0.18) {
        model.step(by: 5)
      }

      Spacer(minLength: 18)

      Button {
        model.showTerritory.toggle()
      } label: {
        Image(systemName: "square.grid.3x3.middle.filled")
          .font(.system(size: 18, weight: .semibold))
          .frame(width: 44, height: 42)
      }
      .buttonStyle(QixiCapsuleButtonStyle(isSelected: model.showTerritory))
      .accessibilityLabel(L10n.text(.boardTerritory))
    }
  }
}

struct RepeatControlButton: View {
  var systemName: String
  var interval: TimeInterval
  var action: () -> Void
  @State private var timer: Timer?

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 17, weight: .semibold))
      .frame(width: 44, height: 42)
      .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
      .background(QixiColor.controlSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(QixiColor.separator, lineWidth: 0.8)
      )
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in startIfNeeded() }
          .onEnded { _ in stop() }
      )
      .onDisappear(perform: stop)
      .accessibilityLabel(systemName)
  }

  private func startIfNeeded() {
    guard timer == nil else { return }
    action()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      action()
    }
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
  }
}

struct QixiCapsuleButtonStyle: ButtonStyle {
  var isSelected = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .semibold))
      .lineLimit(1)
      .minimumScaleFactor(0.68)
      .foregroundStyle(isSelected ? QixiColor.hermesBlue : QixiColor.ink)
      .padding(.horizontal, 16)
      .frame(minHeight: 42)
      .background(
        isSelected ? QixiColor.hermesBlue.opacity(0.10) : (configuration.isPressed ? QixiColor.controlSurfacePressed : QixiColor.controlSurface),
        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(isSelected ? QixiColor.hermesBlue.opacity(0.32) : QixiColor.separator, lineWidth: 0.8)
      )
  }
}
