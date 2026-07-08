import SwiftUI

struct LeftAnalysisPane: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    VStack(spacing: 0) {
      WinrateScoreChart(model: model)
        .frame(maxHeight: 210)
        .frame(maxWidth: .infinity)
      HorizontalDivider()

      VariationTreeView(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      HorizontalDivider()

      EngineSelector(model: model)
        .frame(height: 58)
      HorizontalDivider()

      SettingsStrip(model: model)
        .frame(height: 58)
      HorizontalDivider()

      UtilityStrip(model: model)
        .frame(height: 58)
    }
    .padding(.leading, 18)
    .padding(.trailing, 18)
  }
}

struct WinrateScoreChart: View {
  @ObservedObject var model: QixiViewModel
  private let chartInset = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
  private let chartHitTargetSide: CGFloat = 32

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Canvas(rendersAsynchronously: true) { context, size in
        let rect = plotRect(in: size)
        let points = model.chartPoints
        var mid = Path()
        mid.move(to: CGPoint(x: rect.minX, y: rect.midY))
        mid.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.stroke(mid, with: .color(QixiColor.separator), lineWidth: 1)

        let maxPly = Double(model.chartAxisMaxPly)
        let xOf: (ChartPoint) -> CGFloat = { chartX(for: $0, in: rect, maxPly: maxPly) }
        let winY: (ChartPoint) -> CGFloat = { chartWinY(for: $0, in: rect) }
        let scoreY: (ChartPoint) -> CGFloat = { chartScoreY(for: $0, in: rect) }

        for winPath in lineSegments(points, xOf: xOf, yOf: winY) {
          context.stroke(winPath, with: .color(QixiColor.hermesBlue), lineWidth: 2.2)
        }
        for scorePath in lineSegments(points, xOf: xOf, yOf: scoreY) {
          context.stroke(scorePath, with: .color(QixiColor.hermesRed), lineWidth: 2.0)
        }
        drawVertices(points, context: &context, xOf: xOf, yOf: winY, color: QixiColor.hermesBlue)
        drawVertices(points, context: &context, xOf: xOf, yOf: scoreY, color: QixiColor.hermesRed)

        let refX = rect.minX + rect.width * CGFloat(Double(model.currentPly) / maxPly)
        var ref = Path()
        ref.move(to: CGPoint(x: refX, y: rect.minY))
        ref.addLine(to: CGPoint(x: refX, y: rect.maxY))
        context.stroke(ref, with: .color(QixiColor.separatorStrong), style: StrokeStyle(lineWidth: 1, dash: [5, 6]))
      }

      GeometryReader { proxy in
        ForEach(chartHitTargets(in: proxy.size)) { target in
          Button {
            model.jump(to: target.ply)
          } label: {
            Circle()
              .fill(Color.white.opacity(0.001))
              .frame(width: chartHitTargetSide, height: chartHitTargetSide)
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .position(target.point)
          .accessibilityLabel(L10n.moveNumber(target.ply))
          .accessibilityIdentifier("chart-point-\(target.id)")
        }
      }

      if let currentPoint = model.currentChartPoint {
        HStack(spacing: 12) {
          Text(NumberText.winrate(currentPoint.winrate))
            .foregroundStyle(QixiColor.hermesBlue)
          Text(NumberText.score(currentPoint.scoreMean))
            .foregroundStyle(QixiColor.hermesRed)
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .padding(.top, 12)
        .padding(.trailing, 10)
      }
    }
  }

  private struct ChartHitTarget: Identifiable {
    var id: String
    var ply: Int
    var point: CGPoint
  }

  private func plotRect(in size: CGSize) -> CGRect {
    CGRect(
      x: chartInset.leading,
      y: chartInset.top,
      width: max(1, size.width - chartInset.leading - chartInset.trailing),
      height: max(1, size.height - chartInset.top - chartInset.bottom)
    )
  }

  private func chartX(for point: ChartPoint, in rect: CGRect, maxPly: Double) -> CGFloat {
    rect.minX + rect.width * CGFloat(Double(point.ply) / maxPly)
  }

  private func chartWinY(for point: ChartPoint, in rect: CGRect) -> CGFloat {
    rect.minY + rect.height * CGFloat(1.0 - point.winrate)
  }

  private func chartScoreY(for point: ChartPoint, in rect: CGRect) -> CGFloat {
    rect.midY - CGFloat(point.scoreMean) * rect.height / 24.0
  }

  private func chartHitTargets(in size: CGSize) -> [ChartHitTarget] {
    let rect = plotRect(in: size)
    let maxPly = Double(model.chartAxisMaxPly)
    var targets: [ChartHitTarget] = []
    targets.reserveCapacity(model.chartPoints.count * 2)
    for point in model.chartPoints {
      let x = chartX(for: point, in: rect, maxPly: maxPly)
      targets.append(
        ChartHitTarget(
          id: "win-\(point.ply)",
          ply: point.ply,
          point: CGPoint(x: x, y: chartWinY(for: point, in: rect))
        )
      )
      targets.append(
        ChartHitTarget(
          id: "score-\(point.ply)",
          ply: point.ply,
          point: CGPoint(x: x, y: chartScoreY(for: point, in: rect))
        )
      )
    }
    return targets
  }

  private func lineSegments(
    _ points: [ChartPoint],
    xOf: (ChartPoint) -> CGFloat,
    yOf: (ChartPoint) -> CGFloat
  ) -> [Path] {
    var paths: [Path] = []
    var path = Path()
    var segmentPointCount = 0
    var previousPly: Int?
    for point in points {
      let cgPoint = CGPoint(x: xOf(point), y: yOf(point))
      if let previousPly, point.ply == previousPly + 1 {
        path.addLine(to: cgPoint)
        segmentPointCount += 1
      } else {
        if segmentPointCount > 1 {
          paths.append(path)
        }
        path = Path()
        path.move(to: cgPoint)
        segmentPointCount = 1
      }
      previousPly = point.ply
    }
    if segmentPointCount > 1 {
      paths.append(path)
    }
    return paths
  }

  private func drawVertices(
    _ points: [ChartPoint],
    context: inout GraphicsContext,
    xOf: (ChartPoint) -> CGFloat,
    yOf: (ChartPoint) -> CGFloat,
    color: Color
  ) {
    let radius: CGFloat = points.count > 80 ? 1.6 : 2.2
    for point in points {
      let center = CGPoint(x: xOf(point), y: yOf(point))
      let rect = CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.92)))
    }
  }
}

struct VariationTreeView: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    GeometryReader { proxy in
      let layout = VariationTreeLayout(tree: model.variationTree, availableHeight: proxy.size.height)
      ScrollView([.horizontal, .vertical], showsIndicators: true) {
        ZStack(alignment: .topLeading) {
          Canvas(rendersAsynchronously: true) { context, _ in
            for edge in layout.edges {
              context.stroke(edge.path, with: .color(QixiColor.separatorStrong), lineWidth: 1.7)
            }
          }
          ForEach(layout.nodes) { node in
            Button {
              model.jump(toVariationNode: node.id)
            } label: {
              if node.isInitial {
                RoundedRectangle(cornerRadius: 2)
                  .fill(Color.white)
                  .frame(width: 15, height: 15)
                  .overlay(RoundedRectangle(cornerRadius: 2).stroke(QixiColor.separatorStrong, lineWidth: 1))
              } else {
                Circle()
                  .fill(variationNodeColor(node))
                  .frame(width: node.isCurrent ? 17 : 13, height: node.isCurrent ? 17 : 13)
                  .overlay(Circle().stroke(Color.white.opacity(node.isCurrent ? 0.92 : 0.0), lineWidth: 2))
              }
            }
            .buttonStyle(.plain)
            .frame(width: VariationTreeLayout.hitTargetSide, height: VariationTreeLayout.hitTargetSide)
            .contentShape(Rectangle())
            .position(node.point)
            .accessibilityLabel(L10n.moveNumber(node.ply))
          }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .accessibilityIdentifier("variation-tree-120hz-canvas")
      }
      .scrollIndicators(.automatic)
    }
  }

  private func variationNodeColor(_ node: VariationTreeLayout.Node) -> Color {
    guard let qualityDeltaPercent = node.qualityDeltaPercent else {
      return Color.white
    }
    return CandidatePalette.color(deltaPercent: qualityDeltaPercent)
  }
}

struct EngineSelector: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    HStack(spacing: 8) {
      ForEach(AnalysisEngine.allCases) { engine in
        Button {
          model.selectEngine(engine)
        } label: {
          Label {
            Text(engine.title)
              .lineLimit(1)
              .minimumScaleFactor(0.62)
          } icon: {
            Image(systemName: engine.symbolName)
          }
          .labelStyle(.titleAndIcon)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(QixiSegmentButtonStyle(isSelected: model.selectedEngine == engine))
      }
    }
    .padding(.vertical, 8)
  }
}

struct SettingsStrip: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    HStack(spacing: 12) {
      NumberField(title: L10n.text(.settingsKomi), value: $model.komi, fractionDigits: 1)
      NumberField(title: L10n.text(.settingsWideRootNoise), value: $model.rootNoise, fractionDigits: 2)
    }
    .padding(.vertical, 8)
  }
}

struct NumberField: View {
  var title: String
  @Binding var value: Double
  var fractionDigits: Int

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(QixiColor.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.52)
        .layoutPriority(1)
      Spacer()
      TextField(title, value: $value, format: .number.precision(.fractionLength(fractionDigits)))
        .multilineTextAlignment(.trailing)
        .keyboardType(.decimalPad)
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .frame(width: 76)
    }
    .font(.system(size: 14, weight: .medium))
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 40)
    .background(QixiColor.controlSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(QixiColor.separator, lineWidth: 0.8))
  }
}

struct UtilityStrip: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    HStack(spacing: 12) {
      UtilityButton(title: L10n.text(.utilityNew), systemName: "plus") {
        model.newGame()
      }
      UtilityButton(title: L10n.text(.utilityCamera), systemName: "camera.viewfinder") {
        model.openUtilitySheet(.camera)
      }
      UtilityButton(title: L10n.text(.utilityImport), systemName: "square.and.arrow.down") {
        model.openUtilitySheet(.importGame)
      }
      UtilityButton(title: L10n.text(.utilitySync), systemName: "icloud.and.arrow.up") {
        model.openUtilitySheet(.sync)
      }
    }
    .padding(.vertical, 8)
  }
}

struct UtilityButton: View {
  var title: String
  var systemName: String
  var action: () -> Void = {}

  var body: some View {
    Button(action: action) {
      Label {
        Text(title)
          .lineLimit(1)
          .minimumScaleFactor(0.58)
      } icon: {
        Image(systemName: systemName)
      }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(QixiCapsuleButtonStyle())
  }
}

struct QixiSegmentButtonStyle: ButtonStyle {
  var isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .semibold))
      .lineLimit(1)
      .minimumScaleFactor(0.62)
      .foregroundStyle(isSelected ? QixiColor.hermesBlue : QixiColor.ink)
      .frame(height: 40)
      .background(
        isSelected ? QixiColor.hermesBlue.opacity(0.10) : (configuration.isPressed ? QixiColor.controlSurfacePressed : QixiColor.controlSurface),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(isSelected ? QixiColor.hermesBlue.opacity(0.32) : QixiColor.separator, lineWidth: 0.8)
      )
  }
}
