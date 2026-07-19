import SwiftUI

struct BoardView: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        BoardBackgroundCanvas()
          .frame(width: side, height: side)

        TerritoryCanvas(model: model, analyzeDisplay: model.analyzeDisplay)
          .frame(width: side, height: side)

        StoneLayer(model: model, side: side)

        RecognitionPreviewCanvas(model: model)
          .frame(width: side, height: side)

        CandidateCanvas(analyzeDisplay: model.analyzeDisplay)
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
      // Grid follows BoardGeometry so edge stones/candidates share the same inset.
      let origin = BoardGeometry.intersection(x: 0, y: 0, side: side)
      let far = BoardGeometry.intersection(
        x: BoardGeometry.boardSize - 1,
        y: BoardGeometry.boardSize - 1,
        side: side
      )
      for index in 0..<BoardGeometry.boardSize {
        let axisX = BoardGeometry.intersection(x: index, y: 0, side: side).x
        var vertical = Path()
        vertical.move(to: CGPoint(x: axisX, y: origin.y))
        vertical.addLine(to: CGPoint(x: axisX, y: far.y))
        context.stroke(vertical, with: .color(lineColor), lineWidth: lineWidth)

        let axisY = BoardGeometry.intersection(x: 0, y: index, side: side).y
        var horizontal = Path()
        horizontal.move(to: CGPoint(x: origin.x, y: axisY))
        horizontal.addLine(to: CGPoint(x: far.x, y: axisY))
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
  /// Fraction of board side reserved around the grid so edge stones, candidate
  /// disks, and rank tags are not clipped by the canvas bounds.
  /// Candidate radius ≈ 0.40·step and rank sits ~0.62·radius outside the disk;
  /// 0.05 leaves a small wood margin past that extent.
  static let pad: CGFloat = 0.05
  /// Distance between adjacent intersections as a fraction of board side.
  static var step: CGFloat { (1.0 - 2.0 * pad) / CGFloat(boardSize - 1) }

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
  /// 0…1 appear weight for newly placed stones (forward-step / play). Full board loads skip fade.
  @State private var appearWeightByStoneID: [Int: Double] = [:]
  @State private var appearTicker: Task<Void, Never>?

  /// Match candidate enter timing (~280 ms).
  private static let appearRatePerSecond = 1.0 / 0.28

  var body: some View {
    let stoneSize = side * BoardGeometry.step * 0.94
    let outlineLineWidth = max(1.4, side * BoardGeometry.step * 0.055)
    let capturedByNextMove = model.nextMoveCapturedBoardPointIDs
    let showCaptureOutlines = model.nextMoveShowsCaptureOutlines
    let stoneIDs = model.visibleBoardStones.map(\.id)
    ZStack {
      ForEach(model.visibleBoardStones) { stone in
        let isCapturedOutline =
          showCaptureOutlines && capturedByNextMove.contains(stone.id)
        let point = BoardGeometry.intersection(x: stone.x, y: stone.y, side: side)
        let weight = min(1.0, max(0.0, appearWeightByStoneID[stone.id] ?? 1.0))
        // Smoothstep so outline → solid reads as a soft gradient, not a linear pop.
        let s = weight * weight * (3.0 - 2.0 * weight)
        if isCapturedOutline {
          // Unanalyzed next-move preview: capture effect as a faint stone outline.
          Circle()
            .strokeBorder(
              stone.color == .black
                ? Color.black.opacity(0.42)
                : Color.white.opacity(0.58),
              lineWidth: outlineLineWidth
            )
            .frame(width: stoneSize * 0.92, height: stoneSize * 0.92)
            .opacity(s)
            .position(point)
        } else {
          BundleImage(name: stone.color == .black ? "black19Yunzi" : "whiteStone")
            .aspectRatio(contentMode: .fit)
            .frame(width: stoneSize, height: stoneSize)
            // Start slightly smaller / transparent so forward-step from a next-move
            // stroke fills in with a gradient rather than a hard pop (esp. no-engine).
            .scaleEffect(0.82 + 0.18 * s)
            .opacity(s)
            .position(point)
        }
      }
    }
    .onAppear {
      reconcileAppearWeights(stoneIDs: stoneIDs, animateNew: false)
    }
    .onChange(of: stoneIDs) { oldIDs, newIDs in
      // Only animate a small number of newcomers (step/play). Bulk load → full opacity.
      let oldSet = Set(oldIDs)
      let newcomers = newIDs.filter { !oldSet.contains($0) }
      reconcileAppearWeights(stoneIDs: newIDs, animateNew: newcomers.count > 0 && newcomers.count <= 4)
    }
  }

  private func reconcileAppearWeights(stoneIDs: [Int], animateNew: Bool) {
    let live = Set(stoneIDs)
    for id in appearWeightByStoneID.keys where !live.contains(id) {
      appearWeightByStoneID.removeValue(forKey: id)
    }
    for id in stoneIDs {
      if appearWeightByStoneID[id] == nil {
        appearWeightByStoneID[id] = animateNew ? 0.0 : 1.0
      }
    }
    if animateNew {
      ensureAppearTicker()
    }
  }

  private func ensureAppearTicker() {
    guard appearTicker == nil else { return }
    appearTicker = Task { @MainActor in
      defer { appearTicker = nil }
      while !Task.isCancelled {
        var any = false
        let dt = 1.0 / 60.0
        for (id, weight) in appearWeightByStoneID {
          if weight < 0.999 {
            appearWeightByStoneID[id] = min(1.0, weight + Self.appearRatePerSecond * dt)
            any = true
          } else if weight != 1.0 {
            appearWeightByStoneID[id] = 1.0
          }
        }
        if !any { return }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }
}

struct CandidateCanvas: View {
  /// Observes analyze plane only — not board stones / chrome.
  @ObservedObject var analyzeDisplay: QixiAnalyzeDisplayModel

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      let side = min(size.width, size.height)
      // Diameter must stay under one grid step so neighboring plates do not collide.
      // step * 0.40 → diameter ≈ 0.80 of cell gap (was 0.62 → 1.24, heavy overlap).
      let analysisRadius = side * BoardGeometry.step * 0.40
      let stoneRadius = side * BoardGeometry.step * 0.47
      for candidate in analyzeDisplay.overlays {
        let radius = candidate.usesStoneSizedContinuationMarker ? stoneRadius : analysisRadius
        let point = BoardGeometry.intersection(x: candidate.x, y: candidate.y, side: side)
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

        // Enter/exit weight: 0 = leaving/entering display set, 1 = stable in set.
        let weight = min(1.0, max(0.0, candidate.presentationWeight))

        if candidate.usesStoneSizedContinuationMarker {
          // Unanalyzed next move: faint stone outline (no analysis disk fill).
          // Still respect weight so forced next-move markers can fade with the set.
          if weight < 0.05 { continue }
          drawFaintStoneOutline(
            in: &context,
            circle: circle,
            radius: radius,
            color: candidate.continuationRingColor ?? .black,
            opacityScale: weight
          )
          continue
        }

        // Color gradient through the −5% display threshold tint while entering/exiting.
        // Keep solid tint expression for contract / identity of the quality color source.
        let solidTint = candidate.colorComponents?.color ?? QixiColor.background
        let fillColor: Color
        if let base = candidate.colorComponents {
          fillColor = CandidatePalette.presentationComponents(base: base, weight: weight).color
        } else {
          fillColor = solidTint.opacity(weight)
        }
        context.fill(Path(ellipseIn: circle), with: .color(fillColor))
        if let ringColor = candidate.continuationRingColor, weight > 0.2 {
          // Analyzed next move: very thin white/black ring on the disk edge.
          drawThinAnalysisEdgeRing(
            in: &context,
            circle: circle,
            radius: radius,
            color: ringColor
          )
        }
        guard candidate.showsAnalysisText, weight > 0.45 else { continue }

        let textOpacity = Double(weight)
        // Compact rank tag just outside the rim (smaller offset than before).
        let rankPoint = CGPoint(x: point.x + radius * 0.62, y: point.y - radius * 0.62)
        context.draw(
          Text(candidate.rankText)
            .font(.system(size: max(7.5, side * 0.011), weight: .bold))
            .foregroundStyle(QixiColor.ink.opacity(textOpacity)),
          at: rankPoint,
          anchor: .center
        )
        let analysisLineOffset = radius * 0.36
        let analysisFontSize = candidateAnalysisFontSize(
          for: candidate,
          radius: radius,
          lineOffset: analysisLineOffset
        )
        context.draw(
          Text(candidate.winrateText)
            .font(.system(size: analysisFontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(textOpacity)),
          at: CGPoint(x: point.x, y: point.y - analysisLineOffset),
          anchor: .center
        )
        context.draw(
          Text(candidate.visitsText)
            .font(.system(size: analysisFontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(textOpacity)),
          at: point,
          anchor: .center
        )
        context.draw(
          Text(candidate.scoreText)
            .font(.system(size: analysisFontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.94 * textOpacity)),
          at: CGPoint(x: point.x, y: point.y + analysisLineOffset),
          anchor: .center
        )
      }
    }
    .accessibilityIdentifier("candidate-120hz-canvas")
  }

  private func drawFaintStoneOutline(
    in context: inout GraphicsContext,
    circle: CGRect,
    radius: CGFloat,
    color: StoneColor,
    opacityScale: Double = 1.0
  ) {
    let lineWidth = max(1.5, radius * 0.085)
    let path = Path(ellipseIn: circle.insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5))
    let s = min(1.0, max(0.0, opacityScale))
    switch color {
    case .black:
      context.stroke(path, with: .color(Color.black.opacity(0.40 * s)), lineWidth: lineWidth)
    case .white:
      // Single soft outline (no dual ink underlay — that drew two black rims).
      // Slightly higher opacity so it stays visible on light board paper without a
      // second stroke.
      context.stroke(path, with: .color(Color.white.opacity(0.94 * s)), lineWidth: lineWidth * 1.05)
    }
  }

  private func drawThinAnalysisEdgeRing(
    in context: inout GraphicsContext,
    circle: CGRect,
    radius: CGFloat,
    color: StoneColor
  ) {
    // Very thin edge ring around the analysis disk.
    let ringWidth = max(1.0, radius * 0.055)
    let ringPath = Path(ellipseIn: circle.insetBy(dx: ringWidth * 0.50, dy: ringWidth * 0.50))
    switch color {
    case .black:
      context.stroke(ringPath, with: .color(Color.black.opacity(0.92)), lineWidth: ringWidth)
    case .white:
      // Single white rim — no dual dark underlay (same dual-edge artifact as faint outline).
      context.stroke(ringPath, with: .color(Color.white.opacity(0.96)), lineWidth: ringWidth)
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
    // Keep three text lines fully inside the smaller plate.
    let widthBound = radius * 1.70 / (CGFloat(safeLength) * 0.55)
    let verticalBound = lineOffset * 0.92
    return min(min(radius * 0.38, widthBound), verticalBound)
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
  @ObservedObject var analyzeDisplay: QixiAnalyzeDisplayModel

  /// Hide faint ownership; aligns with `territoryPoints` filter (~0.16).
  private static let magnitudeThreshold = 0.16
  /// White squares sit on a light board — raise opacity vs black at the same inclination.
  private static let whiteAlphaBoost = 1.55

  var body: some View {
    // Sync draw so ownership squares track the HUD without async lag.
    Canvas(rendersAsynchronously: false) { context, size in
      guard model.showTerritory, analyzeDisplay.hasOwnership else { return }
      let side = min(size.width, size.height)
      // Compact square markers (not disks) centered on empty intersections.
      let halfSide = side * BoardGeometry.step * 0.20
      let occupied = model.occupiedBoardPointIDs
      let ownership = analyzeDisplay.ownership
      guard ownership.count == 361 else { return }
      let threshold = Self.magnitudeThreshold
      let span = max(1e-6, 1.0 - threshold)
      for index in 0..<361 {
        if occupied.contains(index) { continue }
        let value = Double(ownership[index])
        let magnitude = min(1.0, abs(value))
        // Skip weak / uncertain claims so the map stays readable.
        guard magnitude >= threshold else { continue }
        let x = index % 19
        let y = index / 19
        let point = BoardGeometry.intersection(x: x, y: y, side: side)
        // Remap [threshold, 1] → [0, 1], then smoothstep for alpha.
        let normalized = min(1.0, max(0.0, (magnitude - threshold) / span))
        let t = normalized * normalized * (3.0 - 2.0 * normalized)
        let isWhite = value > 0
        let baseAlpha = 0.16 + 0.68 * t
        let alpha = min(0.94, isWhite ? baseAlpha * Self.whiteAlphaBoost : baseAlpha)
        let color = isWhite ? Color.white.opacity(alpha) : Color.black.opacity(alpha)
        let rect = CGRect(
          x: point.x - halfSide,
          y: point.y - halfSide,
          width: halfSide * 2,
          height: halfSide * 2
        )
        context.fill(Path(rect), with: .color(color))
      }
    }
    .allowsHitTesting(false)
  }
}
