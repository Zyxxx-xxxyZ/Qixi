import SwiftUI

struct BoardView: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        BoardBackgroundCanvas()
          .frame(width: side, height: side)

        TerritoryCanvas(model: model)
          .frame(width: side, height: side)

        StoneLayer(model: model, side: side)

        RecognitionPreviewCanvas(model: model)
          .frame(width: side, height: side)

        CandidateCanvas(model: model)
          .frame(width: side, height: side)
      }
      .frame(width: side, height: side)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onEnded { value in
            let point = BoardGeometry.boardPoint(from: value.location, side: side)
            if let point {
              model.play(at: point.x, y: point.y)
            }
          }
      )
      .position(x: proxy.size.width / 2.0, y: proxy.size.height / 2.0)
    }
    .aspectRatio(1, contentMode: .fit)
  }
}

struct BoardBackgroundCanvas: View {
  private let boardColor = QixiColor.background
  private let lineColor = Color.black.opacity(0.72)

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      let side = min(size.width, size.height)
      let rect = CGRect(x: 0, y: 0, width: side, height: side)
      context.fill(Path(rect), with: .color(boardColor))

      let lineWidth = max(1.0, side * 0.0021)
      let edgeInset = lineWidth * 0.5
      func visibleGridCoordinate(_ index: Int) -> CGFloat {
        if index == 0 { return edgeInset }
        if index == BoardGeometry.boardSize - 1 { return side - edgeInset }
        return side * CGFloat(index) * BoardGeometry.step
      }
      for index in 0..<BoardGeometry.boardSize {
        let axis = visibleGridCoordinate(index)
        let startVertical = CGPoint(x: axis, y: edgeInset)
        let endVertical = CGPoint(x: axis, y: side - edgeInset)
        var vertical = Path()
        vertical.move(to: startVertical)
        vertical.addLine(to: endVertical)
        context.stroke(vertical, with: .color(lineColor), lineWidth: lineWidth)

        let startHorizontal = CGPoint(x: edgeInset, y: axis)
        let endHorizontal = CGPoint(x: side - edgeInset, y: axis)
        var horizontal = Path()
        horizontal.move(to: startHorizontal)
        horizontal.addLine(to: endHorizontal)
        context.stroke(horizontal, with: .color(lineColor), lineWidth: lineWidth)
      }

      let starRadius = max(3.2, side * 0.0062)
      for x in [3, 9, 15] {
        for y in [3, 9, 15] {
          let point = BoardGeometry.intersection(x: x, y: y, side: side)
          let starRect = CGRect(
            x: point.x - starRadius,
            y: point.y - starRadius,
            width: starRadius * 2,
            height: starRadius * 2
          )
          context.fill(Path(ellipseIn: starRect), with: .color(lineColor))
        }
      }
    }
    .accessibilityIdentifier("plain-board-background-canvas")
  }
}

enum BoardGeometry {
  static let boardSize = 19
  static let pad: CGFloat = 0.0
  static let step: CGFloat = 1.0 / 18.0

  static func intersection(x: Int, y: Int, side: CGFloat) -> CGPoint {
    CGPoint(
      x: side * (pad + CGFloat(x) * step),
      y: side * (pad + CGFloat(y) * step)
    )
  }

  static func boardPoint(from location: CGPoint, side: CGFloat) -> (x: Int, y: Int)? {
    let x = Int(round((location.x / side - pad) / step))
    let y = Int(round((location.y / side - pad) / step))
    guard x >= 0, x < boardSize, y >= 0, y < boardSize else { return nil }
    let exact = intersection(x: x, y: y, side: side)
    guard abs(exact.x - location.x) <= side * step * 0.52 else { return nil }
    guard abs(exact.y - location.y) <= side * step * 0.52 else { return nil }
    return (x, y)
  }
}

struct StoneLayer: View {
  @ObservedObject var model: QixiViewModel
  var side: CGFloat

  var body: some View {
    let stoneSize = side * BoardGeometry.step * 0.94
    let capturedByNextMove = model.nextMoveCapturedBoardPointIDs
    ZStack {
      ForEach(model.visibleBoardStones) { stone in
        let isCapturedByNextMove = capturedByNextMove.contains(stone.id)
        BundleImage(name: stone.color == .black ? "black19Yunzi" : "whiteStone")
          .aspectRatio(contentMode: .fit)
          .frame(width: stoneSize, height: stoneSize)
          .opacity(isCapturedByNextMove ? 0.34 : 1.0)
          .saturation(isCapturedByNextMove ? 0.35 : 1.0)
          .position(BoardGeometry.intersection(x: stone.x, y: stone.y, side: side))
      }
    }
  }
}

struct CandidateCanvas: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      let side = min(size.width, size.height)
      let analysisRadius = side * BoardGeometry.step * 0.62
      let stoneRadius = side * BoardGeometry.step * 0.47
      for candidate in model.visibleCandidateOverlays {
        let radius = candidate.usesStoneSizedContinuationMarker ? stoneRadius : analysisRadius
        let point = BoardGeometry.intersection(x: candidate.x, y: candidate.y, side: side)
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(
          Path(ellipseIn: circle),
          with: .color(candidate.colorComponents?.color ?? QixiColor.background)
        )
        if let ringColor = candidate.continuationRingColor {
          drawContinuationRing(
            in: &context,
            circle: circle,
            radius: radius,
            color: ringColor
          )
        }
        guard candidate.showsAnalysisText else { continue }

        let rankPoint = CGPoint(x: point.x + radius * 0.78, y: point.y - radius * 0.78)
        context.draw(
          Text(candidate.rankText)
            .font(.system(size: max(9, side * 0.014), weight: .bold))
            .foregroundStyle(QixiColor.ink),
          at: rankPoint,
          anchor: .center
        )
        let analysisLineOffset = radius * 0.44
        let analysisFontSize = candidateAnalysisFontSize(
          for: candidate,
          radius: radius,
          lineOffset: analysisLineOffset
        )
        context.draw(
          Text(candidate.winrateText)
            .font(.system(size: analysisFontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white),
          at: CGPoint(x: point.x, y: point.y - analysisLineOffset),
          anchor: .center
        )
        context.draw(
          Text(candidate.visitsText)
            .font(.system(size: analysisFontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white),
          at: point,
          anchor: .center
        )
        context.draw(
          Text(candidate.scoreText)
            .font(.system(size: analysisFontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.94)),
          at: CGPoint(x: point.x, y: point.y + analysisLineOffset),
          anchor: .center
        )
      }
    }
    .accessibilityIdentifier("candidate-120hz-canvas")
  }

  private func drawContinuationRing(
    in context: inout GraphicsContext,
    circle: CGRect,
    radius: CGFloat,
    color: StoneColor
  ) {
    let ringWidth = max(2.2, radius * 0.18)
    switch color {
    case .black:
      let ringPath = Path(ellipseIn: circle.insetBy(dx: ringWidth * 0.50, dy: ringWidth * 0.50))
      context.stroke(ringPath, with: .color(Color.black.opacity(0.90)), lineWidth: ringWidth)
    case .white:
      let ringPath = Path(ellipseIn: circle.insetBy(dx: ringWidth * 0.67, dy: ringWidth * 0.67))
      context.stroke(ringPath, with: .color(QixiColor.ink.opacity(0.62)), lineWidth: ringWidth * 1.34)
      context.stroke(ringPath, with: .color(Color.white.opacity(0.98)), lineWidth: ringWidth * 0.82)
    }
  }

  private func candidateAnalysisFontSize(
    for candidate: VisibleCandidateOverlay,
    radius: CGFloat,
    lineOffset: CGFloat
  ) -> CGFloat {
    let longestLineLength = max(
      candidate.winrateText.count,
      max(candidate.visitsText.count, candidate.scoreText.count)
    )
    let safeLength = max(1, longestLineLength)
    let widthBound = radius * 1.52 / (CGFloat(safeLength) * 0.58)
    let verticalBound = lineOffset * 0.78
    return min(min(radius * 0.34, widthBound), verticalBound)
  }
}

struct RecognitionPreviewCanvas: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      guard let preview = model.lastBoardRecognition else { return }
      let side = min(size.width, size.height)
      let radius = side * BoardGeometry.step * 0.46
      let liveStones = model.visibleStoneColorsByID
      let strokeStyle = StrokeStyle(lineWidth: max(2.0, side * 0.004), lineCap: .round, dash: [max(4.0, side * 0.008), max(3.0, side * 0.006)])

      for stone in preview.stones {
        let point = BoardGeometry.intersection(x: stone.x, y: stone.y, side: side)
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2.0, height: radius * 2.0)
        let path = Path(ellipseIn: circle)
        let matchesLiveStone = liveStones[stone.id] == stone.color
        if !matchesLiveStone {
          let fillColor = stone.color == .black
            ? Color.black.opacity(0.36)
            : Color.white.opacity(0.56)
          context.fill(path, with: .color(fillColor))
        }
        context.stroke(path, with: .color(QixiColor.hermesBlue.opacity(0.92)), style: strokeStyle)
      }
    }
    .allowsHitTesting(false)
    .accessibilityIdentifier("board-recognition-preview-canvas")
  }
}

struct TerritoryCanvas: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      guard model.showTerritory else { return }
      let side = min(size.width, size.height)
      let square = side * BoardGeometry.step / 3.0
      let occupied = model.occupiedBoardPointIDs
      for item in model.territory {
        if occupied.contains(item.id) { continue }
        let point = BoardGeometry.intersection(x: item.x, y: item.y, side: side)
        let alpha = min(0.72, 0.18 + abs(item.ownership) * 0.5)
        let color = item.ownership > 0 ? Color.white.opacity(alpha) : Color.black.opacity(alpha)
        let rect = CGRect(x: point.x - square / 2.0, y: point.y - square / 2.0, width: square, height: square)
        context.fill(Path(rect), with: .color(color))
      }
    }
    .allowsHitTesting(false)
  }
}
