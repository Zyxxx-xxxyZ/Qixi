import SwiftUI
import UIKit

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

      // On-device switch timing: between tree and engine strip so stalls are visible live.
      QixiSwitchMonitorView(monitor: model.switchMonitor)
        .padding(.vertical, 6)
      HorizontalDivider()

      EngineSelector(model: model)
        .frame(height: 58)
      HorizontalDivider()

      // Height grows when the in-pane decimal pad is open so fields stay visible
      // (must not fix 58pt — that clipped the pad and forced the system keyboard hack).
      SettingsStrip(model: model)
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
  @ObservedObject private var analyzeDisplay: QixiAnalyzeDisplayModel
  /// Settles series / axis / ref-line toward live targets so HUD jitter and rescales do not
  /// snap the polyline every visit.
  @StateObject private var presentation = ChartPresentation()
  private let chartInset = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)
  private let chartHitTargetSide: CGFloat = 32

  init(model: QixiViewModel) {
    self.model = model
    self._analyzeDisplay = ObservedObject(wrappedValue: model.analyzeDisplay)
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      // Sync Canvas: async redraw lags contentOffset-style updates and makes the line stutter.
      Canvas(rendersAsynchronously: false) { context, size in
        let rect = plotRect(in: size)
        let points = presentation.samples
        let scoreHalfRange = presentation.scoreHalfRange
        let maxPly = max(1.0, presentation.maxPly)

        var mid = Path()
        mid.move(to: CGPoint(x: rect.minX, y: rect.midY))
        mid.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.stroke(mid, with: .color(QixiColor.separator), lineWidth: 1)

        let xOf: (ChartPresentation.Sample) -> CGFloat = { sample in
          chartX(ply: sample.ply, in: rect, maxPly: maxPly)
        }
        let winY: (ChartPresentation.Sample) -> CGFloat = { sample in
          chartWinY(winrate: sample.winrate, in: rect)
        }
        let scoreY: (ChartPresentation.Sample) -> CGFloat = { sample in
          chartScoreY(scoreMean: sample.scoreMean, in: rect, halfRange: scoreHalfRange)
        }

        // Straight polyline segments only — not Catmull-Rom / Bézier curves.
        // Smoothness is temporal (ChartPresentation settles values), not geometric.
        let winStyle = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        let scoreStyle = StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
        for winPath in lineSegments(points, xOf: xOf, yOf: winY) {
          context.stroke(winPath, with: .color(QixiColor.hermesBlue), style: winStyle)
        }
        for scorePath in lineSegments(points, xOf: xOf, yOf: scoreY) {
          context.stroke(scorePath, with: .color(QixiColor.hermesRed), style: scoreStyle)
        }
        drawVertices(points, context: &context, xOf: xOf, yOf: winY, color: QixiColor.hermesBlue)
        drawVertices(points, context: &context, xOf: xOf, yOf: scoreY, color: QixiColor.hermesRed)

        let refX = rect.minX + rect.width * CGFloat(presentation.refPly / maxPly)
        var ref = Path()
        ref.move(to: CGPoint(x: refX, y: rect.minY))
        ref.addLine(to: CGPoint(x: refX, y: rect.maxY))
        context.stroke(
          ref,
          with: .color(QixiColor.separatorStrong),
          style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 6])
        )
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

      if let currentPoint = presentation.currentDisplayPoint(atPly: model.currentPly)
        ?? model.currentChartPoint
      {
        HStack(spacing: 12) {
          Text(NumberText.winrate(currentPoint.winrate))
            .foregroundStyle(QixiColor.hermesBlue)
          Text(NumberText.score(currentPoint.scoreMean))
            .foregroundStyle(QixiColor.hermesRed)
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .padding(.top, 12)
        .padding(.trailing, 10)
        .accessibilityIdentifier("chart-live-engine-metrics")
      }
    }
    // Never call presentation.sync from `body` — publishing @Published there can
    // infinite-loop the view graph (empty chart on launch froze startup).
    .onAppear { pushChartTargets() }
    .onChange(of: model.currentPly) { _, _ in pushChartTargets() }
    .onChange(of: model.chartAxisMaxPly) { _, _ in pushChartTargets() }
    .onChange(of: model.selectedEngine) { _, _ in pushChartTargets() }
    .onChange(of: analyzeDisplay.rootWinrate) { _, _ in pushChartTargets() }
    .onChange(of: analyzeDisplay.rootScoreMean) { _, _ in pushChartTargets() }
    .onChange(of: analyzeDisplay.rootVisits) { _, _ in pushChartTargets() }
    // Cache writes / tree navigation invalidate chart series via model.objectWillChange.
    .onReceive(model.objectWillChange) { _ in
      DispatchQueue.main.async { pushChartTargets() }
    }
  }

  private func pushChartTargets() {
    let targetPoints = model.chartPoints
    let targetHalfRange = scoreAxisHalfRange(points: targetPoints, live: model.currentChartPoint)
    presentation.sync(
      points: targetPoints,
      maxPly: model.chartAxisMaxPly,
      currentPly: model.currentPly,
      scoreHalfRange: targetHalfRange
    )
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

  private func chartX(ply: Int, in rect: CGRect, maxPly: Double) -> CGFloat {
    rect.minX + rect.width * CGFloat(Double(ply) / max(1.0, maxPly))
  }

  private func chartWinY(winrate: Double, in rect: CGRect) -> CGFloat {
    let wr = min(1.0, max(0.0, winrate))
    return rect.minY + rect.height * CGFloat(1.0 - wr)
  }

  /// Half-range of the score axis (points). Default ±12 matches the old fixed scale;
  /// expands when any series/live score exceeds that so the red line stays in-plot.
  private func scoreAxisHalfRange(points: [ChartPoint], live: ChartPoint?) -> Double {
    var peak = 0.0
    for point in points {
      guard point.scoreMean.isFinite else { continue }
      peak = max(peak, abs(point.scoreMean))
    }
    if let live, live.scoreMean.isFinite {
      peak = max(peak, abs(live.scoreMean))
    }
    // 12% headroom so peaks are not glued to the plot edge.
    let padded = peak * 1.12
    // Floor at 12 → same visual scale as the previous fixed height/24 mapping for small leads.
    return max(12.0, padded)
  }

  private func chartScoreY(scoreMean: Double, in rect: CGRect, halfRange: Double) -> CGFloat {
    let range = max(0.5, halfRange)
    let score = scoreMean.isFinite ? scoreMean : 0.0
    let y = rect.midY - CGFloat(score) * rect.height / CGFloat(2.0 * range)
    // Hard clamp: non-finite / extreme values never leave the plot rect.
    return min(rect.maxY, max(rect.minY, y))
  }

  private func chartHitTargets(in size: CGSize) -> [ChartHitTarget] {
    let rect = plotRect(in: size)
    let maxPly = max(1.0, presentation.maxPly)
    let scoreHalfRange = presentation.scoreHalfRange
    var targets: [ChartHitTarget] = []
    targets.reserveCapacity(presentation.samples.count * 2)
    for sample in presentation.samples {
      let x = chartX(ply: sample.ply, in: rect, maxPly: maxPly)
      targets.append(
        ChartHitTarget(
          id: "win-\(sample.ply)",
          ply: sample.ply,
          point: CGPoint(x: x, y: chartWinY(winrate: sample.winrate, in: rect))
        )
      )
      targets.append(
        ChartHitTarget(
          id: "score-\(sample.ply)",
          ply: sample.ply,
          point: CGPoint(
            x: x,
            y: chartScoreY(scoreMean: sample.scoreMean, in: rect, halfRange: scoreHalfRange)
          )
        )
      )
    }
    return targets
  }

  /// Straight line segments per consecutive-ply run (gaps break the series).
  private func lineSegments(
    _ points: [ChartPresentation.Sample],
    xOf: (ChartPresentation.Sample) -> CGFloat,
    yOf: (ChartPresentation.Sample) -> CGFloat
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
    _ points: [ChartPresentation.Sample],
    context: inout GraphicsContext,
    xOf: (ChartPresentation.Sample) -> CGFloat,
    yOf: (ChartPresentation.Sample) -> CGFloat,
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

// MARK: - Chart presentation (settled series)

/// Display-linked interpolation of chart series so live HUD / cache writes do not snap the
/// polyline or score axis every visit. Geometry still follows ply; values ease toward targets.
@MainActor
private final class ChartPresentation: NSObject, ObservableObject {
  struct Sample: Identifiable, Equatable {
    var id: Int { ply }
    var ply: Int
    var winrate: Double
    var scoreMean: Double
  }

  @Published private(set) var samples: [Sample] = []
  @Published private(set) var scoreHalfRange: Double = 12
  @Published private(set) var maxPly: Double = 1
  @Published private(set) var refPly: Double = 0

  private struct Target {
    var winrate: Double
    var scoreMean: Double
  }

  private var targets: [Int: Target] = [:]
  private var targetOrder: [Int] = []
  private var targetHalfRange: Double = 12
  private var targetMaxPly: Double = 1
  private var targetRefPly: Double = 0
  private var displayLink: CADisplayLink?
  private var lastTickMediaTime: CFTimeInterval = 0

  /// ~95% settle times (3τ). Values ease faster than axis so the line tracks analysis.
  private static let valueDuration = 0.20
  private static let axisDuration = 0.32
  private static let refDuration = 0.22

  deinit {
    displayLink?.invalidate()
  }

  func currentDisplayPoint(atPly ply: Int) -> ChartPoint? {
    guard let sample = samples.first(where: { $0.ply == ply }) else { return nil }
    return ChartPoint(ply: sample.ply, winrate: sample.winrate, scoreMean: sample.scoreMean)
  }

  @discardableResult
  func sync(
    points: [ChartPoint],
    maxPly: Int,
    currentPly: Int,
    scoreHalfRange: Double
  ) -> Bool {
    // Targets only — display samples ease on the display-link. Never publish when
    // nothing changed: assigning `samples = []` while already empty used to re-enter
    // SwiftUI forever and freeze launch.
    targetOrder = points.map(\.ply)
    targets = Dictionary(uniqueKeysWithValues: points.map {
      ($0.ply, Target(winrate: $0.winrate, scoreMean: $0.scoreMean))
    })
    targetHalfRange = max(12.0, scoreHalfRange)
    targetMaxPly = Double(max(1, maxPly))
    targetRefPly = Double(currentPly)

    let targetPlies = Set(targetOrder)
    var next = samples.filter { targetPlies.contains($0.ply) }
    let existing = Set(next.map(\.ply))
    for ply in targetOrder {
      guard let t = targets[ply], !existing.contains(ply) else { continue }
      // New ply: land on the target immediately so the series grows cleanly.
      next.append(Sample(ply: ply, winrate: t.winrate, scoreMean: t.scoreMean))
    }
    next.sort { $0.ply < $1.ply }

    // Structure / first paint: only write @Published when content actually differs.
    if next != samples {
      samples = next
    }
    // Snap axis/ref when we have no samples yet (or first non-empty structure paint)
    // only if values differ — avoid no-op publishes.
    // Note: parameter `maxPly` shadows the property — always use `self.` for display state.
    if samples.isEmpty || !needsAnimation {
      if abs(self.scoreHalfRange - targetHalfRange) > 1e-9 {
        self.scoreHalfRange = targetHalfRange
      }
      if abs(self.maxPly - targetMaxPly) > 1e-9 {
        self.maxPly = targetMaxPly
      }
      if abs(self.refPly - targetRefPly) > 1e-9 {
        self.refPly = targetRefPly
      }
    }

    if needsAnimation {
      ensureTicker()
    }
    return true
  }

  private var needsAnimation: Bool {
    if abs(scoreHalfRange - targetHalfRange) > 0.02 { return true }
    if abs(maxPly - targetMaxPly) > 0.02 { return true }
    if abs(refPly - targetRefPly) > 0.02 { return true }
    for sample in samples {
      guard let t = targets[sample.ply] else { continue }
      if abs(sample.winrate - t.winrate) > 0.0008 { return true }
      if abs(sample.scoreMean - t.scoreMean) > 0.02 { return true }
    }
    // Missing display rows for targets also requires a publish (handled in sync).
    if samples.count != targetOrder.count { return true }
    return false
  }

  private func ensureTicker() {
    guard displayLink == nil else { return }
    lastTickMediaTime = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func handleDisplayLink(_ link: CADisplayLink) {
    let now = link.targetTimestamp
    let dt = min(0.05, max(1.0 / 120.0, now - lastTickMediaTime))
    lastTickMediaTime = now
    let still = step(dt: dt)
    if !still {
      link.invalidate()
      if displayLink === link {
        displayLink = nil
      }
    }
  }

  @discardableResult
  private func step(dt: Double) -> Bool {
    var any = false
    var nextSamples = samples
    for i in nextSamples.indices {
      let ply = nextSamples[i].ply
      guard let t = targets[ply] else { continue }
      let wr = settle(nextSamples[i].winrate, t.winrate, duration: Self.valueDuration, dt: dt)
      let sc = settle(nextSamples[i].scoreMean, t.scoreMean, duration: Self.valueDuration, dt: dt)
      if abs(wr - nextSamples[i].winrate) > 1e-6 || abs(sc - nextSamples[i].scoreMean) > 1e-6 {
        any = true
      }
      nextSamples[i].winrate = wr
      nextSamples[i].scoreMean = sc
      // Snap residual noise.
      if abs(wr - t.winrate) < 0.0005 { nextSamples[i].winrate = t.winrate }
      if abs(sc - t.scoreMean) < 0.01 { nextSamples[i].scoreMean = t.scoreMean }
    }
    if nextSamples != samples {
      samples = nextSamples
      any = true
    }

    let half = settle(scoreHalfRange, targetHalfRange, duration: Self.axisDuration, dt: dt)
    if abs(half - scoreHalfRange) > 1e-6 {
      scoreHalfRange = abs(half - targetHalfRange) < 0.02 ? targetHalfRange : half
      any = true
    }
    let axis = settle(maxPly, targetMaxPly, duration: Self.axisDuration, dt: dt)
    if abs(axis - maxPly) > 1e-6 {
      maxPly = abs(axis - targetMaxPly) < 0.02 ? targetMaxPly : axis
      any = true
    }
    let ref = settle(refPly, targetRefPly, duration: Self.refDuration, dt: dt)
    if abs(ref - refPly) > 1e-6 {
      refPly = abs(ref - targetRefPly) < 0.02 ? targetRefPly : ref
      any = true
    }
    return any || needsAnimation
  }

  private func settle(_ value: Double, _ target: Double, duration: Double, dt: Double) -> Double {
    let tau = max(0.001, duration / 3.0)
    let alpha = 1.0 - exp(-dt / tau)
    return value + (target - value) * alpha
  }
}

struct VariationTreeView: View {
  @ObservedObject var model: QixiViewModel

  var body: some View {
    GeometryReader { proxy in
      // Equatable skips body/updateUIView when only unrelated VM fields publish
      // (candidates / visits / chart), which is the common analysis-tick path.
      VariationTreeLaidOutView(
        tree: model.variationTree,
        availableHeight: proxy.size.height,
        viewportSize: proxy.size,
        onSelect: { nodeID in model.jump(toVariationNode: nodeID) }
      )
      .equatable()
    }
  }
}

private struct VariationTreeLaidOutView: View, Equatable {
  let tree: VariationTree
  let availableHeight: CGFloat
  let viewportSize: CGSize
  let onSelect: (String) -> Void

  /// Presentation state so appear / dye / current-highlight / layout shifts all ease with a gradient.
  /// Does not drive SwiftUI body via @Published — presentation frames go straight to UIKit.
  @StateObject private var presentation = VariationTreePresentation()

  static func == (lhs: VariationTreeLaidOutView, rhs: VariationTreeLaidOutView) -> Bool {
    lhs.tree == rhs.tree
      && lhs.availableHeight == rhs.availableHeight
      && lhs.viewportSize.width == rhs.viewportSize.width
      && lhs.viewportSize.height == rhs.viewportSize.height
  }

  var body: some View {
    let layout = VariationTreeLayout(tree: tree, availableHeight: availableHeight)
    // Prefer final layout position for scroll decisions — animated mid-lane points can
    // falsely look “near the edge” while the settled node is still well on-screen.
    let focusPoint = layout.nodes.first(where: { $0.id == tree.currentNodeID })?.point
      ?? presentation.displayPoint(for: tree.currentNodeID)
    // Content size is layout-stable only. Never expand from animated presentation points
    // (contentSize churn mid-pan stutters UIScrollView).
    let contentSize = CGSize(
      width: layout.size.width,
      height: max(layout.size.height, availableHeight)
    )
    VariationTreeUIScrollView(
      contentSize: contentSize,
      focusPoint: focusPoint,
      currentNodeID: tree.currentNodeID,
      viewportSize: viewportSize,
      layoutNodes: layout.nodes,
      presentation: presentation,
      onSelect: onSelect
    )
    .onAppear {
      presentation.reconcile(tree: tree, layout: layout, animateNew: false)
    }
    .onChange(of: tree) { _, newTree in
      let newLayout = VariationTreeLayout(tree: newTree, availableHeight: availableHeight)
      presentation.reconcile(tree: newTree, layout: newLayout, animateNew: true)
    }
    .onChange(of: availableHeight) { _, height in
      let newLayout = VariationTreeLayout(tree: tree, availableHeight: height)
      presentation.reconcile(tree: tree, layout: newLayout, animateNew: false)
    }
  }
}

// MARK: - Gradient presentation for tree motion

/// Receives presentation frames without going through SwiftUI body evaluation.
@MainActor
private protocol VariationTreePresentationRenderer: AnyObject {
  func variationTreePresentationDidUpdate(
    nodes: [VariationTreePresentation.DisplayNode],
    edges: [VariationTreePresentation.DisplayEdge]
  )
}

/// Animates tree node appear/exit, dye color, current highlight, and layout point shifts.
/// Pushes frames to a UIKit renderer instead of @Published — long trees must not rebuild
/// a SwiftUI hosting hierarchy every CADisplayLink tick while the user is scrolling.
@MainActor
private final class VariationTreePresentation: NSObject, ObservableObject {
  struct DisplayNode: Identifiable {
    var id: String
    var ply: Int
    var point: CGPoint
    var isInitial: Bool
    var appearWeight: Double
    var currentWeight: Double
    var fill: CandidateColorComponents
  }

  struct DisplayEdge {
    var from: CGPoint
    var mid: CGPoint?
    var to: CGPoint
    var opacity: Double
  }

  private(set) var displayNodes: [DisplayNode] = []
  private(set) var displayEdges: [DisplayEdge] = []
  weak var renderer: VariationTreePresentationRenderer?

  private struct Slot {
    var ply: Int
    var isInitial: Bool
    var point: CGPoint
    var targetPoint: CGPoint
    var appear: Double
    var targetAppear: Double
    var current: Double
    var targetCurrent: Double
    var color: CandidateColorComponents
    var targetColor: CandidateColorComponents
    var edgeParentID: String?
  }

  private var slots: [String: Slot] = [:]
  private var edgePairs: [(from: String, to: String)] = []
  /// VSync-linked ticker (not Task.sleep) so appear/lane motion shares the display clock
  /// with auto-scroll and does not phase-stutter against it.
  private var displayLink: CADisplayLink?
  private var lastTickMediaTime: CFTimeInterval = 0
  /// Finger is down / flinging — never push frames or tick (scroll must be compositor-only).
  private var userScrolling = false
  /// Long trees: skip multi-frame dye/appear gradients (one snap paint).
  private var preferSnapUpdates = false

  private static let appearRate = 1.0 / 0.28
  private static let exitRate = 1.0 / 0.32
  private static let colorRate = 1.0 / 0.30
  private static let currentRate = 1.0 / 0.22
  /// Point/lane motion must be proportional to remaining distance (not px/s).
  /// `approach` is linear in value-space and crawls when lanes reflow by tens of points.
  /// Settle ~95% of the gap in this wall time regardless of pixel distance.
  private static let pointSettleDuration = 0.26
  /// Above this node count, continuous CADisplayLink paints fight long-tree scroll.
  private static let snapNodeThreshold = 64

  private static let whiteUndyed = CandidateColorComponents(red: 1, green: 1, blue: 1, alpha: 1)

  deinit {
    displayLink?.invalidate()
  }

  func displayPoint(for id: String) -> CGPoint? {
    slots[id].map(\.point)
  }

  /// Freeze presentation while the user pans/decelerates so strip images stay stable.
  func setUserScrolling(_ scrolling: Bool) {
    if userScrolling == scrolling { return }
    userScrolling = scrolling
    if scrolling {
      // Drop the ticker immediately — no array rebuilds / tile invalidation mid-pan.
      displayLink?.invalidate()
      displayLink = nil
    } else {
      // Catch up to any targets accumulated while the finger was down.
      if needsAnimation && !preferSnapUpdates {
        ensureTicker()
      } else {
        snapAllSlotsToTargets()
        publish()
      }
    }
  }

  func reconcile(tree: VariationTree, layout: VariationTreeLayout, animateNew: Bool) {
    preferSnapUpdates = layout.nodes.count >= Self.snapNodeThreshold
    let allowAnimation = animateNew && !preferSnapUpdates && !userScrolling
    let layoutByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
    let liveIDs = Set(layoutByID.keys)

    for id in slots.keys where !liveIDs.contains(id) {
      slots[id]?.targetAppear = 0
    }

    for node in layout.nodes {
      let targetColor: CandidateColorComponents
      if let k = node.qualityDeltaPercent {
        targetColor = CandidatePalette.components(deltaPercent: k)
      } else {
        targetColor = Self.whiteUndyed
      }
      if var slot = slots[node.id] {
        slot.ply = node.ply
        slot.isInitial = node.isInitial
        slot.targetPoint = node.point
        slot.targetAppear = 1
        slot.targetCurrent = node.isCurrent ? 1 : 0
        slot.targetColor = targetColor
        if !allowAnimation {
          slot.point = node.point
          slot.appear = 1
          slot.current = slot.targetCurrent
          slot.color = targetColor
        }
        slots[node.id] = slot
      } else {
        let startAppear = allowAnimation ? 0.0 : 1.0
        slots[node.id] = Slot(
          ply: node.ply,
          isInitial: node.isInitial,
          point: node.point,
          targetPoint: node.point,
          appear: startAppear,
          targetAppear: 1,
          current: node.isCurrent ? 1 : 0,
          targetCurrent: node.isCurrent ? 1 : 0,
          color: targetColor,
          targetColor: targetColor,
          edgeParentID: nil
        )
      }
    }

    // Rebuild edge list from tree; parent endpoints follow animated slots.
    edgePairs = tree.edges.map { ($0.from, $0.to) }
    for edge in tree.edges {
      if slots[edge.to] != nil {
        slots[edge.to]?.edgeParentID = edge.from
      }
    }

    if userScrolling {
      // Defer paint until the pan ends so scroll stays a pure layer translate.
      return
    }

    publish()
    if needsAnimation && allowAnimation {
      ensureTicker()
    } else if needsAnimation {
      snapAllSlotsToTargets()
      publish()
    }
  }

  private func snapAllSlotsToTargets() {
    var finished: [String] = []
    for (id, var slot) in slots {
      slot.point = slot.targetPoint
      slot.appear = slot.targetAppear
      slot.current = slot.targetCurrent
      slot.color = slot.targetColor
      if slot.targetAppear <= 0 {
        finished.append(id)
      }
      slots[id] = slot
    }
    for id in finished {
      slots.removeValue(forKey: id)
    }
  }

  private var needsAnimation: Bool {
    for slot in slots.values {
      if abs(slot.appear - slot.targetAppear) > 0.01 { return true }
      if abs(slot.current - slot.targetCurrent) > 0.01 { return true }
      if abs(slot.point.x - slot.targetPoint.x) > 0.4 { return true }
      if abs(slot.point.y - slot.targetPoint.y) > 0.4 { return true }
      if abs(slot.color.red - slot.targetColor.red) > 0.01 { return true }
      if abs(slot.color.green - slot.targetColor.green) > 0.01 { return true }
      if abs(slot.color.blue - slot.targetColor.blue) > 0.01 { return true }
      if abs(slot.color.alpha - slot.targetColor.alpha) > 0.01 { return true }
    }
    return false
  }

  private func ensureTicker() {
    guard displayLink == nil else { return }
    guard !userScrolling, !preferSnapUpdates else { return }
    lastTickMediaTime = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(handlePresentationDisplayLink(_:)))
    // Default run-loop mode only — NOT .common. Tracking mode must not run dye paints
    // while UIScrollView is moving (that was a major chop source on long trees).
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .default)
    displayLink = link
  }

  @objc private func handlePresentationDisplayLink(_ link: CADisplayLink) {
    if userScrolling || preferSnapUpdates {
      link.invalidate()
      if displayLink === link { displayLink = nil }
      return
    }
    let now = link.targetTimestamp
    let dt = min(0.05, max(1.0 / 60.0, now - lastTickMediaTime))
    lastTickMediaTime = now
    let still = step(dt: dt)
    publish()
    if !still {
      link.invalidate()
      if displayLink === link {
        displayLink = nil
      }
    }
  }

  @discardableResult
  private func step(dt: Double) -> Bool {
    let d = min(0.05, max(0.001, dt))
    var any = false
    var finished: [String] = []

    for (id, var slot) in slots {
      // Appear / exit
      if abs(slot.appear - slot.targetAppear) > 0.01 {
        let rate = slot.targetAppear > slot.appear ? Self.appearRate : Self.exitRate
        slot.appear = approach(slot.appear, slot.targetAppear, rate: rate, dt: d)
        any = true
      } else {
        slot.appear = slot.targetAppear
        if slot.targetAppear <= 0 {
          finished.append(id)
        }
      }
      // Current highlight
      if abs(slot.current - slot.targetCurrent) > 0.01 {
        slot.current = approach(slot.current, slot.targetCurrent, rate: Self.currentRate, dt: d)
        any = true
      } else {
        slot.current = slot.targetCurrent
      }
      // Layout point (lane reassignment / reflow) — exponential settle, not constant px/s
      let dx = abs(slot.point.x - slot.targetPoint.x)
      let dy = abs(slot.point.y - slot.targetPoint.y)
      if dx > 0.4 || dy > 0.4 {
        let nx = settleToward(slot.point.x, slot.targetPoint.x, duration: Self.pointSettleDuration, dt: d)
        let ny = settleToward(slot.point.y, slot.targetPoint.y, duration: Self.pointSettleDuration, dt: d)
        slot.point = CGPoint(x: nx, y: ny)
        any = true
      } else {
        slot.point = slot.targetPoint
      }
      // Dye color gradient
      let c = lerpColor(slot.color, slot.targetColor, rate: Self.colorRate, dt: d)
      if colorDistance(c, slot.color) > 0.002 { any = true }
      slot.color = c
      slots[id] = slot
    }

    for id in finished {
      slots.removeValue(forKey: id)
    }
    return any || needsAnimation
  }

  private func publish() {
    displayNodes = slots.map { id, slot -> DisplayNode in
      let s = smoothstep(slot.appear)
      return DisplayNode(
        id: id,
        ply: slot.ply,
        point: slot.point,
        isInitial: slot.isInitial,
        appearWeight: s,
        currentWeight: smoothstep(slot.current),
        fill: slot.color
      )
    }
    .sorted { a, b in
      if a.ply != b.ply { return a.ply < b.ply }
      return a.id < b.id
    }

    displayEdges = edgePairs.compactMap { pair in
      guard let to = slots[pair.to], let from = slots[pair.from] else { return nil }
      let opacity = Double(smoothstep(min(from.appear, to.appear))) * 0.95
      guard opacity > 0.02 else { return nil }
      let mid: CGPoint?
      if abs(from.point.y - to.point.y) < 0.5 {
        mid = nil
      } else {
        mid = CGPoint(x: from.point.x, y: to.point.y)
      }
      return DisplayEdge(from: from.point, mid: mid, to: to.point, opacity: opacity)
    }

    renderer?.variationTreePresentationDidUpdate(nodes: displayNodes, edges: displayEdges)
  }

  /// Constant-speed approach for unit-interval weights (appear / current). Completes in ~1/rate seconds.
  private func approach(_ value: Double, _ target: Double, rate: Double, dt: Double) -> Double {
    if value < target {
      return min(target, value + rate * dt)
    }
    return max(target, value - rate * dt)
  }

  private func approach(_ value: CGFloat, _ target: CGFloat, rate: Double, dt: Double) -> CGFloat {
    CGFloat(approach(Double(value), Double(target), rate: rate, dt: dt))
  }

  /// Distance-proportional exponential settle. Same wall-clock feel for 8px or 80px lane shifts.
  /// `duration` is approximate time to cover ~95% of the remaining gap (3 time-constants).
  private func settleToward(_ value: CGFloat, _ target: CGFloat, duration: Double, dt: Double) -> CGFloat {
    let tau = max(0.001, duration / 3.0)
    let alpha = 1.0 - exp(-dt / tau)
    return value + (target - value) * CGFloat(alpha)
  }

  private func smoothstep(_ t: Double) -> Double {
    let x = min(1, max(0, t))
    return x * x * (3 - 2 * x)
  }

  private func lerpColor(
    _ a: CandidateColorComponents,
    _ b: CandidateColorComponents,
    rate: Double,
    dt: Double
  ) -> CandidateColorComponents {
    let t = min(1.0, rate * dt)
    return CandidateColorComponents(
      red: a.red + (b.red - a.red) * t,
      green: a.green + (b.green - a.green) * t,
      blue: a.blue + (b.blue - a.blue) * t,
      alpha: a.alpha + (b.alpha - a.alpha) * t
    )
  }

  private func colorDistance(_ a: CandidateColorComponents, _ b: CandidateColorComponents) -> Double {
    abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue) + abs(a.alpha - b.alpha)
  }
}

/// UIKit scroll host for the variation tree.
///
/// Smooth long-tree scrolling requires **zero draw work during pan**:
/// - Pre-baked strip `UIImageView`s for the full content (not on-demand tile layers)
/// - On-demand tile layers stuttered in the *middle* of long trees (continuous
///   tile generation); near either end, tiles were already warm so it felt fine
/// - Presentation ticker paused while the user is dragging / decelerating
/// - No per-node hit UIViews; taps are spatial lookups
///
/// Auto-pans only when the current node is on/past a viewport edge (with a small
/// stone-sized margin), or on first layout. Mid-screen nodes — including those in
/// the right half but not near the edge — must not re-center.
private struct VariationTreeUIScrollView: UIViewRepresentable {
  var contentSize: CGSize
  var focusPoint: CGPoint?
  var currentNodeID: String
  var viewportSize: CGSize
  var layoutNodes: [VariationTreeLayout.Node]
  var presentation: VariationTreePresentation
  var onSelect: (String) -> Void

  /// Keep this small (≈ node + pad). A large fractional “comfort” band used to
  /// re-center whenever the node left the middle ~56% of the viewport.
  fileprivate static var edgeMargin: CGFloat { 22 }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.backgroundColor = .clear
    scroll.showsHorizontalScrollIndicator = true
    scroll.showsVerticalScrollIndicator = true
    scroll.alwaysBounceHorizontal = true
    scroll.alwaysBounceVertical = true
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.clipsToBounds = true
    scroll.delegate = context.coordinator
    scroll.decelerationRate = .fast
    // Let the scroll view win over delayed touch delivery so pans feel immediate.
    scroll.delaysContentTouches = false
    scroll.canCancelContentTouches = true
    scroll.isDirectionalLockEnabled = false
    scroll.accessibilityIdentifier = "variation-tree-120hz-canvas"

    let draw = VariationTreeDrawView(frame: .zero)
    draw.onSelect = { [weak coordinator = context.coordinator] id in
      coordinator?.onSelect?(id)
    }
    scroll.addSubview(draw)

    context.coordinator.scrollView = scroll
    context.coordinator.drawView = draw
    context.coordinator.onSelect = onSelect
    context.coordinator.presentation = presentation
    presentation.renderer = context.coordinator
    draw.apply(nodes: presentation.displayNodes, edges: presentation.displayEdges)
    return scroll
  }

  func updateUIView(_ scroll: UIScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onSelect = onSelect
    coordinator.presentation = presentation
    if presentation.renderer !== coordinator {
      presentation.renderer = coordinator
      coordinator.drawView?.apply(nodes: presentation.displayNodes, edges: presentation.displayEdges)
    }

    let size = CGSize(
      width: max(contentSize.width, viewportSize.width),
      height: max(contentSize.height, viewportSize.height)
    )
    if scroll.contentSize != size {
      scroll.contentSize = size
    }

    // Full-content draw view — size follows content, origin stays .zero. Scroll only
    // changes contentOffset; no frame thrash, no setNeedsDisplay on pan.
    if let drawView = coordinator.drawView {
      let frame = CGRect(origin: .zero, size: size)
      if drawView.frame != frame {
        drawView.frame = frame
      }
      let hits = layoutNodes.map { (id: $0.id, point: $0.point, ply: $0.ply) }
      drawView.setHitTargets(hits)
    }

    let nodeChanged = coordinator.lastCurrentNodeID != currentNodeID
    coordinator.lastCurrentNodeID = currentNodeID
    let needsInitial = !coordinator.didInitialFocus

    // Only consider auto-pan when the current node identity changes (or first paint).
    guard needsInitial || nodeChanged else { return }

    let animated = coordinator.didInitialFocus
    coordinator.didInitialFocus = true
    coordinator.scheduleBringIntoViewIfNeeded(
      on: focusPoint,
      in: scroll,
      contentSize: size,
      animated: animated,
      forceCenter: needsInitial
    )
  }

  final class Coordinator: NSObject, UIScrollViewDelegate, VariationTreePresentationRenderer {
    weak var scrollView: UIScrollView?
    var drawView: VariationTreeDrawView?
    weak var presentation: VariationTreePresentation?
    var lastCurrentNodeID: String?
    var didInitialFocus = false
    var onSelect: ((String) -> Void)?
    private var workItem: DispatchWorkItem?

    /// UIKit drives contentOffset on the animation system (compositor-friendly).
    private var offsetAnimator: UIViewPropertyAnimator?
    private weak var animatingScrollView: UIScrollView?
    private var scrollTo: CGPoint = .zero
    private var isUserScrollActive = false

    deinit {
      offsetAnimator?.stopAnimation(true)
    }

    func variationTreePresentationDidUpdate(
      nodes: [VariationTreePresentation.DisplayNode],
      edges: [VariationTreePresentation.DisplayEdge]
    ) {
      // Never paint mid-pan — tiles would invalidate under a moving scroll layer.
      guard !isUserScrollActive else { return }
      drawView?.apply(nodes: nodes, edges: edges)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      setUserScrollActive(true)
      // Interrupt programmatic pans so the finger always wins.
      stopScrollAnimation(snapToTarget: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate {
        setUserScrollActive(false)
      }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      setUserScrollActive(false)
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
      setUserScrollActive(false)
    }

    private func setUserScrollActive(_ active: Bool) {
      if isUserScrollActive == active { return }
      isUserScrollActive = active
      presentation?.setUserScrolling(active)
    }

    // Intentionally NO scrollViewDidScroll → setNeedsDisplay. Scroll must be free.

    func scheduleBringIntoViewIfNeeded(
      on point: CGPoint?,
      in scroll: UIScrollView,
      contentSize: CGSize,
      animated: Bool,
      forceCenter: Bool
    ) {
      // Don't fight the user mid-gesture.
      if isUserScrollActive { return }
      workItem?.cancel()
      let work = DispatchWorkItem { [weak self, weak scroll] in
        guard let self, let scroll else { return }
        if self.isUserScrollActive { return }
        self.bringIntoViewIfNeeded(
          on: point,
          in: scroll,
          contentSize: contentSize,
          animated: animated,
          forceCenter: forceCenter,
          attempt: 0
        )
      }
      workItem = work
      DispatchQueue.main.async(execute: work)
    }

    func bringIntoViewIfNeeded(
      on point: CGPoint?,
      in scroll: UIScrollView,
      contentSize: CGSize,
      animated: Bool,
      forceCenter: Bool,
      attempt: Int
    ) {
      guard let point else { return }
      if isUserScrollActive { return }
      scroll.layoutIfNeeded()
      let bounds = scroll.bounds.size
      if bounds.width <= 1 || bounds.height <= 1 {
        guard attempt < 6 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak scroll] in
          guard let self, let scroll else { return }
          self.bringIntoViewIfNeeded(
            on: point,
            in: scroll,
            contentSize: contentSize,
            animated: animated,
            forceCenter: forceCenter,
            attempt: attempt + 1
          )
        }
        return
      }

      // Not first paint: only pan when the node is on/past a viewport edge.
      if !forceCenter && isInsideViewport(point: point, in: scroll) {
        return
      }

      let offset = offsetToReveal(
        point: point,
        in: scroll,
        contentSize: contentSize,
        forceCenter: forceCenter
      )
      let dx = abs(offset.x - scroll.contentOffset.x)
      let dy = abs(offset.y - scroll.contentOffset.y)
      guard dx > 1.5 || dy > 1.5 else { return }

      if animated {
        startGradientScroll(to: offset, in: scroll)
      } else {
        stopScrollAnimation(snapToTarget: false)
        scroll.contentOffset = offset
      }
    }

    /// First layout: center. Otherwise: minimum delta so the node sits just inside
    /// the edge margin — no full re-center when the node merely neared the side.
    private func offsetToReveal(
      point: CGPoint,
      in scroll: UIScrollView,
      contentSize: CGSize,
      forceCenter: Bool
    ) -> CGPoint {
      let bounds = scroll.bounds.size
      let maxX = max(0, contentSize.width - bounds.width)
      let maxY = max(0, contentSize.height - bounds.height)
      let margin = VariationTreeUIScrollView.edgeMargin

      if forceCenter {
        let targetX = point.x - bounds.width * 0.5
        let targetY = point.y - bounds.height * 0.5
        return CGPoint(
          x: min(max(0, targetX), maxX),
          y: min(max(0, targetY), maxY)
        )
      }

      var ox = scroll.contentOffset.x
      var oy = scroll.contentOffset.y
      let left = ox + margin
      let right = ox + bounds.width - margin
      let top = oy + margin
      let bottom = oy + bounds.height - margin

      if point.x < left {
        ox -= (left - point.x)
      } else if point.x > right {
        ox += (point.x - right)
      }
      if point.y < top {
        oy -= (top - point.y)
      } else if point.y > bottom {
        oy += (point.y - bottom)
      }

      return CGPoint(
        x: min(max(0, ox), maxX),
        y: min(max(0, oy), maxY)
      )
    }

    /// Soft ease-in-out pan via UIViewPropertyAnimator (UIKit timing + interruptible).
    private func startGradientScroll(to target: CGPoint, in scroll: UIScrollView) {
      if isUserScrollActive { return }
      stopScrollAnimation(snapToTarget: false)

      let from = scroll.contentOffset
      let distance = hypot(target.x - from.x, target.y - from.y)
      let duration = min(0.52, max(0.34, TimeInterval(distance) / 360.0))
      scrollTo = target
      animatingScrollView = scroll

      let timing = UICubicTimingParameters(
        controlPoint1: CGPoint(x: 0.33, y: 0.00),
        controlPoint2: CGPoint(x: 0.20, y: 1.00)
      )
      let animator = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
      animator.addAnimations {
        scroll.contentOffset = target
      }
      animator.addCompletion { [weak self, weak scroll] position in
        guard let self else { return }
        self.offsetAnimator = nil
        self.animatingScrollView = nil
        if position == .end {
          scroll?.contentOffset = target
        }
      }
      offsetAnimator = animator
      animator.startAnimation()
    }

    private func stopScrollAnimation(snapToTarget: Bool) {
      guard let animator = offsetAnimator else {
        if snapToTarget, let scroll = animatingScrollView {
          scroll.contentOffset = scrollTo
        }
        animatingScrollView = nil
        return
      }
      animator.stopAnimation(true)
      if snapToTarget, let scroll = animatingScrollView {
        scroll.contentOffset = scrollTo
      }
      offsetAnimator = nil
      animatingScrollView = nil
    }

    /// True when the node is fully inside the viewport (with a small edge margin).
    /// Does **not** require the node to sit in the center of the screen.
    private func isInsideViewport(point: CGPoint, in scroll: UIScrollView) -> Bool {
      let visible = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
      let margin = VariationTreeUIScrollView.edgeMargin
      var zone = visible.insetBy(dx: margin, dy: margin)
      if zone.width < 1 || zone.height < 1 {
        zone = visible
      }
      return zone.contains(point)
    }
  }
}

// MARK: - Pre-baked strip tree drawing (middle-of-tree scroll-safe)

/// Full-content tree surface as a filmstrip of pre-rasterized `UIImageView`s.
///
/// Why pre-bake (not on-demand tiles): when the viewport sits in the *middle* of a
/// long mainline (first and last nodes both off-screen), every pan generates new
/// tiles on demand — classic mid-content stutter. Near either end, tiles were
/// already warm so scrolling felt fine. Pre-baking strips once per presentation
/// commit means the scroll view only translates existing images everywhere.
private final class VariationTreeDrawView: UIView {
  private var displayNodes: [VariationTreePresentation.DisplayNode] = []
  private var displayEdges: [VariationTreePresentation.DisplayEdge] = []
  private var hitTargets: [(id: String, point: CGPoint, ply: Int)] = []
  private var stripViews: [UIImageView] = []
  private var bakedContentSize: CGSize = .zero
  private var bakeGeneration: UInt64 = 0
  var onSelect: ((String) -> Void)?

  /// Horizontal strip width in points. ~6 plies at xGap 48; keeps bake cost and
  /// image count balanced for long games.
  private static let stripWidth: CGFloat = 288
  /// Matches `QixiColor.separatorStrong` (0.130/0.140/0.165 @ 0.46).
  private static let separator = UIColor(red: 0.130, green: 0.140, blue: 0.165, alpha: 0.46)

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isAccessibilityElement = false
    // Strips own the pixels; this view never draw(_:) during scroll.
    contentMode = .redraw
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.cancelsTouchesInView = false
    addGestureRecognizer(tap)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Content size arrives after the first apply; bake once bounds are real.
    if bounds.width > 1, bounds.height > 1,
       bounds.size != bakedContentSize || stripViews.isEmpty
    {
      rebuildStrips()
    }
  }

  func apply(
    nodes: [VariationTreePresentation.DisplayNode],
    edges: [VariationTreePresentation.DisplayEdge]
  ) {
    displayNodes = nodes
    displayEdges = edges
    bakeGeneration &+= 1
    if bounds.width > 1, bounds.height > 1 {
      rebuildStrips()
    }
  }

  func setHitTargets(_ targets: [(id: String, point: CGPoint, ply: Int)]) {
    hitTargets = targets
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    let content = gesture.location(in: self)
    // Match previous SwiftUI hit target size (VariationTreeLayout.hitTargetSide).
    let half = VariationTreeLayout.hitTargetSide * 0.5
    let maxD2 = half * half
    var bestID: String?
    var bestD2 = maxD2
    for target in hitTargets {
      let dx = target.point.x - content.x
      let dy = target.point.y - content.y
      let d2 = dx * dx + dy * dy
      if d2 <= bestD2 {
        bestD2 = d2
        bestID = target.id
      }
    }
    if let bestID {
      onSelect?(bestID)
    }
  }

  /// Rasterize the whole tree into vertical strips once. Scroll only moves these views.
  private func rebuildStrips() {
    let size = bounds.size
    guard size.width > 1, size.height > 1 else { return }

    let nodes = displayNodes
    let edges = displayEdges
    let generation = bakeGeneration

    // Tear down previous filmstrip.
    for view in stripViews {
      view.removeFromSuperview()
    }
    stripViews.removeAll(keepingCapacity: true)

    let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    format.preferredRange = .standard

    var originX: CGFloat = 0
    while originX < size.width {
      let width = min(Self.stripWidth, size.width - originX)
      let stripRect = CGRect(x: originX, y: 0, width: width, height: size.height)
      // Overscan so edge strokes / node radii are not clipped on strip boundaries.
      let cull = stripRect.insetBy(dx: -20, dy: -20)

      let renderer = UIGraphicsImageRenderer(size: stripRect.size, format: format)
      let image = renderer.image { ctx in
        let cg = ctx.cgContext
        cg.translateBy(x: -originX, y: 0)
        Self.drawTree(nodes: nodes, edges: edges, cull: cull, in: cg)
      }

      // If a newer apply landed mid-bake, drop partial filmstrip; next apply/layout redos.
      if generation != bakeGeneration {
        for view in stripViews {
          view.removeFromSuperview()
        }
        stripViews.removeAll(keepingCapacity: true)
        bakedContentSize = .zero
        return
      }

      let imageView = UIImageView(image: image)
      imageView.frame = stripRect
      imageView.isUserInteractionEnabled = false
      imageView.contentMode = .scaleToFill
      // Avoid per-strip offscreen passes during scroll.
      imageView.layer.drawsAsynchronously = false
      addSubview(imageView)
      stripViews.append(imageView)
      originX += width
    }

    bakedContentSize = size
  }

  /// Shared CoreGraphics painter for one cull rect (content coordinates).
  private static func drawTree(
    nodes: [VariationTreePresentation.DisplayNode],
    edges: [VariationTreePresentation.DisplayEdge],
    cull: CGRect,
    in cg: CGContext
  ) {
    for edge in edges {
      guard edgeIntersectsCull(edge, cull: cull) else { continue }
      cg.setStrokeColor(separator.withAlphaComponent(edge.opacity).cgColor)
      cg.setLineWidth(1.7)
      cg.setLineCap(.round)
      cg.setLineJoin(.round)
      cg.beginPath()
      cg.move(to: edge.from)
      if let mid = edge.mid {
        cg.addLine(to: mid)
      }
      cg.addLine(to: edge.to)
      cg.strokePath()
    }

    for node in nodes {
      guard node.appearWeight > 0.02 else { continue }
      if node.point.x < cull.minX - 16 || node.point.x > cull.maxX + 16
        || node.point.y < cull.minY - 16 || node.point.y > cull.maxY + 16
      {
        continue
      }

      let scale = 0.86 + 0.14 * node.appearWeight
      if node.isInitial {
        let side: CGFloat = 15 * scale
        let nodeRect = CGRect(
          x: node.point.x - side * 0.5,
          y: node.point.y - side * 0.5,
          width: side,
          height: side
        )
        let path = UIBezierPath(roundedRect: nodeRect, cornerRadius: 2)
        UIColor.white.withAlphaComponent(node.appearWeight).setFill()
        path.fill()
        separator.withAlphaComponent(node.appearWeight).setStroke()
        path.lineWidth = 1
        path.stroke()
      } else {
        let side = (13.0 + 4.0 * node.currentWeight) * scale
        let nodeRect = CGRect(
          x: node.point.x - side * 0.5,
          y: node.point.y - side * 0.5,
          width: side,
          height: side
        )
        let path = UIBezierPath(ovalIn: nodeRect)
        let fill = node.fill
        UIColor(
          red: fill.red,
          green: fill.green,
          blue: fill.blue,
          alpha: fill.alpha * node.appearWeight * 0.92
        ).setFill()
        path.fill()
        if node.currentWeight > 0.02 {
          UIColor.white
            .withAlphaComponent(0.92 * node.currentWeight * node.appearWeight)
            .setStroke()
          path.lineWidth = 2
          path.stroke()
        }
      }
    }
  }

  private static func edgeIntersectsCull(
    _ edge: VariationTreePresentation.DisplayEdge,
    cull: CGRect
  ) -> Bool {
    var minX = min(edge.from.x, edge.to.x)
    var maxX = max(edge.from.x, edge.to.x)
    var minY = min(edge.from.y, edge.to.y)
    var maxY = max(edge.from.y, edge.to.y)
    if let mid = edge.mid {
      minX = min(minX, mid.x)
      maxX = max(maxX, mid.x)
      minY = min(minY, mid.y)
      maxY = max(maxY, mid.y)
    }
    let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      .insetBy(dx: -2, dy: -2)
    return bounds.intersects(cull)
  }

  // MARK: Accessibility

  override func accessibilityElementCount() -> Int {
    min(hitTargets.count, 64)
  }

  override func accessibilityElement(at index: Int) -> Any? {
    guard index >= 0, index < min(hitTargets.count, 64) else { return nil }
    let target = hitTargets[index]
    let element = UIAccessibilityElement(accessibilityContainer: self)
    element.accessibilityLabel = L10n.moveNumber(target.ply)
    element.accessibilityTraits = .button
    let half = VariationTreeLayout.hitTargetSide * 0.5
    element.accessibilityFrameInContainerSpace = CGRect(
      x: target.point.x - half,
      y: target.point.y - half,
      width: VariationTreeLayout.hitTargetSide,
      height: VariationTreeLayout.hitTargetSide
    )
    return element
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
            Text(model.engineSelectorTitle(for: engine))
              .lineLimit(1)
              .minimumScaleFactor(0.62)
          } icon: {
            Image(systemName: model.engineSelectorSymbolName(for: engine))
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
      // Real iOS number text boxes. System keyboard suppressed; a floating pad that
      // matches the iPad number keyboard is anchored *exactly above* the focused field.
      QixiDecimalSettingRow(
        title: L10n.text(.settingsKomi),
        committedValue: model.komi,
        fractionDigits: 1,
        range: QixiAnalysisLimits.minKomi...QixiAnalysisLimits.maxKomi,
        allowsNegative: true
      ) { model.commitKomiSetting($0) }
      QixiDecimalSettingRow(
        title: L10n.text(.settingsWideRootNoise),
        committedValue: model.rootNoise,
        fractionDigits: 2,
        range: QixiAnalysisLimits.minRootNoise...QixiAnalysisLimits.uiMaxRootNoise,
        allowsNegative: false
      ) { model.commitRootNoiseSetting($0) }
      QixiDecimalSettingRow(
        title: L10n.text(.settingsEpisodeDegree),
        committedValue: model.playoutDoublingAdvantage,
        fractionDigits: 2,
        range: QixiAnalysisLimits.minPlayoutDoublingAdvantage...QixiAnalysisLimits.maxPlayoutDoublingAdvantage,
        allowsNegative: true
      ) { model.commitPlayoutDoublingAdvantageSetting($0) }
    }
    .padding(.vertical, 8)
  }
}

/// Compact label + iOS decimal number field for main-page settings.
struct QixiDecimalSettingRow: View {
  var title: String
  var committedValue: Double
  var fractionDigits: Int
  var range: ClosedRange<Double>
  var allowsNegative: Bool
  var onCommit: (Double) -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .foregroundStyle(QixiColor.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.52)
        .layoutPriority(1)
      Spacer(minLength: 4)
      QixiDecimalNumberField(
        committedValue: committedValue,
        fractionDigits: fractionDigits,
        range: range,
        allowsNegative: allowsNegative,
        accessibilityLabel: title,
        onCommit: onCommit
      )
      .frame(width: 72, height: 28)
    }
    .font(.system(size: 14, weight: .medium))
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 40)
    .background(QixiColor.controlSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(QixiColor.separator, lineWidth: 0.8))
  }
}

// MARK: - Floating system-style decimal pad (anchored above the focused field)

/// Presents a compact decimal pad above the active `UITextField`.
/// Exactly one pad; system keyboard suppressed. Tap outside cancels the edit.
@MainActor
enum QixiFloatingDecimalPad {
  private static var hostView: QixiFloatingDecimalPadHost?
  private static var dimmerView: UIControl?
  private static weak var activeField: UITextField?
  private static var allowsNegative = false
  private static var keyboardObserver: NSObjectProtocol?
  private static var isPresenting = false
  /// When true, `textFieldDidEndEditing` reverts draft instead of committing.
  private static var cancelOnEndEditing = false
  /// Field text when editing began — restored on outside-tap cancel.
  private static var editingSnapshot = ""
  private static var isDismissing = false
  /// Drives appear/dismiss without fighting `resignFirstResponder` layout thrash.
  private static var motionAnimator: UIViewPropertyAnimator?

  /// Shared zero-height input view so UIKit never materializes a second (system) pad.
  static func makeSuppressedInputView() -> UIView {
    let input = UIInputView(
      frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 0),
      inputViewStyle: .keyboard
    )
    input.allowsSelfSizing = false
    input.translatesAutoresizingMaskIntoConstraints = false
    let height = input.heightAnchor.constraint(equalToConstant: 0)
    height.priority = .required
    height.isActive = true
    input.isUserInteractionEnabled = false
    input.backgroundColor = .clear
    return input
  }

  /// Call from the field coordinator after resign — true means cancel (do not commit).
  static func consumeCancelOnEndEditing() -> Bool {
    let v = cancelOnEndEditing
    cancelOnEndEditing = false
    return v
  }

  static func present(for field: UITextField, allowsNegative: Bool) {
    // Interrupt an in-flight dismiss so reopening never stacks mid-fade.
    motionAnimator?.stopAnimation(true)
    motionAnimator = nil
    isDismissing = false

    if isPresenting, activeField === field, hostView?.isHidden == false, hostView?.alpha ?? 0 > 0.5 {
      self.allowsNegative = allowsNegative
      hostView?.allowsNegative = allowsNegative
      hostView?.rebuildIfNeeded()
      reposition(animated: true)
      return
    }
    isPresenting = true
    defer { isPresenting = false }

    activeField = field
    self.allowsNegative = allowsNegative
    cancelOnEndEditing = false
    editingSnapshot = field.text ?? ""

    installSuppressedKeyboard(on: field)
    ensureKeyboardObserver()

    guard let window = resolveWindow(for: field) else { return }

    purgeAllHosts(except: nil)
    ensureDimmer(in: window)

    let host: QixiFloatingDecimalPadHost
    if let existing = hostView {
      host = existing
      if host.superview !== window {
        host.removeFromSuperview()
        window.addSubview(host)
      }
    } else {
      let created = QixiFloatingDecimalPadHost()
      created.onInsert = { insert($0) }
      created.onDelete = { deleteBackward() }
      created.onToggleSign = { toggleSign() }
      created.onDone = { requestDone() }
      window.addSubview(created)
      hostView = created
      host = created
    }
    host.allowsNegative = allowsNegative
    host.rebuildIfNeeded()
    host.isHidden = false
    host.layer.removeAllAnimations()
    window.bringSubviewToFront(host)

    // Final frame first (no transform yet), then ease in.
    reposition(animated: false, prepareAppear: true)
    animateAppear()
  }

  /// Commit edit and dismiss (完成). Animate pad out *before* resign so layout
  /// commits do not chop the get-off motion.
  static func requestDone() {
    guard !isDismissing else { return }
    cancelOnEndEditing = false
    dimmerView?.isUserInteractionEnabled = false
    animateDismiss {
      activeField?.resignFirstResponder()
    }
  }

  /// Cancel edit, restore pre-edit text, dismiss (tap outside).
  static func requestCancel() {
    guard !isDismissing else { return }
    cancelOnEndEditing = true
    dimmerView?.isUserInteractionEnabled = false
    if let field = activeField {
      field.text = editingSnapshot
      field.sendActions(for: .editingChanged)
    }
    animateDismiss {
      activeField?.resignFirstResponder()
    }
  }

  static func dismiss(resign: Bool) {
    if resign {
      requestDone()
    } else {
      animateDismiss(completion: nil)
    }
  }

  /// Called from `textFieldDidEndEditing` after commit/cancel handling.
  /// Pad is usually already animating out from requestDone/requestCancel.
  static func detach(field: UITextField) {
    guard activeField === field || activeField == nil else { return }
    if !isDismissing {
      animateDismiss(completion: nil)
    } else {
      // Animation already running — clear field when it finishes (handled there).
    }
  }

  static func reposition(animated: Bool, prepareAppear: Bool = false) {
    // Never re-layout the pad while it is fading out — that caused a visible upward hop
    // before disappearance (frame jump + transform fighting each other).
    guard !isDismissing else { return }
    guard let field = activeField, let host = hostView else { return }
    guard let window = host.superview ?? resolveWindow(for: field) else { return }
    if host.superview !== window {
      host.removeFromSuperview()
      window.addSubview(host)
    }
    if let dimmer = dimmerView, dimmer.superview === window {
      dimmer.frame = window.bounds
      window.insertSubview(dimmer, belowSubview: host)
    }
    host.layoutIfNeeded()
    let padSize = host.preferredSize
    let fieldRect = field.convert(field.bounds, to: window)
    let gap: CGFloat = 10
    var originY = fieldRect.minY - padSize.height - gap
    var placeAbove = true
    if originY < window.safeAreaInsets.top + 6 {
      originY = fieldRect.maxY + gap
      placeAbove = false
    }
    var originX = fieldRect.midX - padSize.width * 0.5
    let minX = window.safeAreaInsets.left + 8
    let maxX = window.bounds.width - window.safeAreaInsets.right - padSize.width - 8
    originX = min(max(originX, minX), max(minX, maxX))
    let frame = CGRect(x: originX, y: originY, width: padSize.width, height: padSize.height)
    host.caretPointsUp = !placeAbove
    let apply = {
      // Always clear transform when parking the frame so no residual drift remains.
      host.transform = .identity
      host.frame = frame
      host.setNeedsLayout()
      host.setNeedsDisplay()
    }
    if prepareAppear {
      apply()
      return
    }
    if animated {
      UIView.animate(
        withDuration: 0.28,
        delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: apply
      )
    } else {
      apply()
    }
  }

  private static func animateAppear() {
    guard let host = hostView, let dimmer = dimmerView else { return }
    motionAnimator?.stopAnimation(true)
    // Pure fade-in (no translation). Transform on dismiss was read as a glitchy hop.
    host.transform = .identity
    host.alpha = 0
    dimmer.alpha = 0
    dimmer.isHidden = false
    dimmer.isUserInteractionEnabled = true

    let timing = UICubicTimingParameters(
      controlPoint1: CGPoint(x: 0.22, y: 1.0),
      controlPoint2: CGPoint(x: 0.36, y: 1.0)
    )
    let animator = UIViewPropertyAnimator(duration: 0.28, timingParameters: timing)
    animator.addAnimations {
      host.alpha = 1
      dimmer.alpha = 1
    }
    animator.addCompletion { _ in
      motionAnimator = nil
    }
    motionAnimator = animator
    animator.startAnimation()
  }

  /// Fade the pad out in place; optional `completion` runs after (e.g. resignFirstResponder).
  private static func animateDismiss(completion: (() -> Void)?) {
    if isDismissing {
      completion?()
      return
    }
    isDismissing = true
    motionAnimator?.stopAnimation(true)

    guard let host = hostView else {
      completion?()
      activeField = nil
      isDismissing = false
      return
    }
    let dimmer = dimmerView
    dimmer?.isUserInteractionEnabled = false

    // Kill any leftover transform so opacity is the only motion (no upward slide).
    host.transform = .identity
    host.layer.removeAllAnimations()
    dimmer?.layer.removeAllAnimations()

    // Soft ease-out cubic, slightly longer so the fade never reads as a snap.
    let timing = UICubicTimingParameters(
      controlPoint1: CGPoint(x: 0.33, y: 0.00),
      controlPoint2: CGPoint(x: 0.20, y: 1.00)
    )
    let animator = UIViewPropertyAnimator(duration: 0.26, timingParameters: timing)
    animator.addAnimations {
      host.alpha = 0
      dimmer?.alpha = 0
    }
    animator.addCompletion { position in
      motionAnimator = nil
      if position == .end {
        host.isHidden = true
        host.transform = .identity
        host.alpha = 1
        dimmer?.isHidden = true
        dimmer?.alpha = 0
        dimmer?.isUserInteractionEnabled = true
      }
      // Resign/commit only after the fade so layout cannot shove the pad mid-flight.
      completion?()
      activeField = nil
      isDismissing = false
    }
    motionAnimator = animator
    animator.startAnimation()
  }

  private static func ensureDimmer(in window: UIWindow) {
    let dimmer: UIControl
    if let existing = dimmerView {
      dimmer = existing
      if dimmer.superview !== window {
        dimmer.removeFromSuperview()
        window.addSubview(dimmer)
      }
    } else {
      let created = UIControl(frame: window.bounds)
      // Clear hit target — no visual veil; tap anywhere outside the pad cancels.
      created.backgroundColor = .clear
      created.addAction(UIAction { _ in
        QixiFloatingDecimalPad.requestCancel()
      }, for: .touchUpInside)
      window.addSubview(created)
      dimmerView = created
      dimmer = created
    }
    dimmer.frame = window.bounds
    dimmer.isHidden = false
    dimmer.alpha = 0
    if let host = hostView {
      window.insertSubview(dimmer, belowSubview: host)
    }
  }

  private static func installSuppressedKeyboard(on field: UITextField) {
    field.inputView = makeSuppressedInputView()
    field.inputAccessoryView = nil
    field.inputAssistantItem.leadingBarButtonGroups = []
    field.inputAssistantItem.trailingBarButtonGroups = []
    field.reloadInputViews()
  }

  private static func ensureKeyboardObserver() {
    guard keyboardObserver == nil else { return }
    keyboardObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillShowNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in
        guard let field = activeField else { return }
        installSuppressedKeyboard(on: field)
        if let host = hostView {
          host.isHidden = false
          host.superview?.bringSubviewToFront(host)
          reposition(animated: false)
        }
      }
    }
  }

  private static func resolveWindow(for field: UITextField) -> UIWindow? {
    if let w = field.window { return w }
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
  }

  private static func purgeAllHosts(except keep: QixiFloatingDecimalPadHost?) {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        for sub in window.subviews {
          guard let pad = sub as? QixiFloatingDecimalPadHost else { continue }
          if pad !== keep {
            pad.removeFromSuperview()
          }
        }
      }
    }
    if let keep {
      hostView = keep
    } else if hostView?.superview == nil {
      hostView = nil
    }
  }

  private static func insert(_ string: String) {
    activeField?.insertText(string)
  }

  private static func deleteBackward() {
    activeField?.deleteBackward()
  }

  private static func toggleSign() {
    guard allowsNegative, let field = activeField else { return }
    var text = field.text ?? ""
    if text.hasPrefix("-") {
      text.removeFirst()
    } else if !text.isEmpty {
      text = "-" + text
    } else {
      text = "-"
    }
    field.text = text
    field.sendActions(for: .editingChanged)
  }
}

/// Compact decimal pad matched to Qixi’s paper UI — light, tight, no phone-letter clutter.
private final class QixiFloatingDecimalPadHost: UIView {
  var onInsert: ((String) -> Void)?
  var onDelete: (() -> Void)?
  var onToggleSign: (() -> Void)?
  var onDone: (() -> Void)?
  var allowsNegative = false
  /// When true, caret is on top (pad sits below the field).
  var caretPointsUp = false

  private let chrome = UIView()
  private let grid = UIStackView()
  private var builtForNegative: Bool?

  // Compact footprint (was ~268×320+ with phone letters + extra action row).
  private let padWidth: CGFloat = 216
  private let keyHeight: CGFloat = 36
  private let keyGap: CGFloat = 5
  private let chromePad: CGFloat = 8
  private let caretHeight: CGFloat = 7

  /// Warm paper surface (app background family).
  private static let paper = UIColor(red: 0.945, green: 0.925, blue: 0.880, alpha: 0.98)
  private static let keyFace = UIColor(red: 1.0, green: 0.995, blue: 0.985, alpha: 1)
  private static let keyPressed = UIColor(red: 0.90, green: 0.875, blue: 0.825, alpha: 1)
  private static let ink = UIColor(red: 0.098, green: 0.105, blue: 0.132, alpha: 1)
  private static let muted = UIColor(red: 0.470, green: 0.494, blue: 0.548, alpha: 1)
  private static let accent = UIColor(red: 0.129, green: 0.322, blue: 0.957, alpha: 1)
  private static let hairline = UIColor(red: 0.130, green: 0.140, blue: 0.165, alpha: 0.16)

  var preferredSize: CGSize {
    // 4 equal rows × 4 columns (digits + side actions), no separate bulky footer.
    let rows: CGFloat = 4
    let gridH = rows * keyHeight + (rows - 1) * keyGap
    let body = chromePad * 2 + gridH
    return CGSize(width: padWidth, height: body + caretHeight)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.14
    layer.shadowRadius = 12
    layer.shadowOffset = CGSize(width: 0, height: 4)

    chrome.backgroundColor = Self.paper
    chrome.layer.cornerRadius = 14
    chrome.layer.cornerCurve = .continuous
    chrome.layer.borderWidth = 0.5
    chrome.layer.borderColor = Self.hairline.cgColor
    chrome.clipsToBounds = true
    addSubview(chrome)

    grid.axis = .vertical
    grid.spacing = keyGap
    grid.distribution = .fillEqually
    chrome.addSubview(grid)

    rebuildIfNeeded()
  }

  required init?(coder: NSCoder) { nil }

  func rebuildIfNeeded() {
    if builtForNegative == allowsNegative, !grid.arrangedSubviews.isEmpty { return }
    builtForNegative = allowsNegative
    grid.arrangedSubviews.forEach {
      grid.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }

    // Compact grid — same key size rhythm throughout (no oversized blue slab):
    // 1 2 3 ⌫
    // 4 5 6 − / ·
    // 7 8 9 .
    // 0 0 0 完成   (0 spans three columns; 完成 matches side-column width)
    let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
    let sideKinds: [KeyKind] = [
      .delete,
      allowsNegative ? .sign : .spacer,
      .digit // "."
    ]

    for row in 0..<3 {
      let stack = makeRow()
      for col in 0..<3 {
        let d = digits[row * 3 + col]
        stack.addArrangedSubview(makeKey(title: d, kind: .digit) { [weak self] in
          self?.onInsert?(d)
        })
      }
      let kind = sideKinds[row]
      if kind == .spacer {
        stack.addArrangedSubview(makeSpacer())
      } else if kind == .digit {
        stack.addArrangedSubview(makeKey(title: ".", kind: .digit) { [weak self] in
          self?.onInsert?(".")
        })
      } else {
        let title = kind == .sign ? "−" : ""
        stack.addArrangedSubview(makeKey(title: title, kind: kind) { [weak self] in
          self?.handleSide(kind)
        })
      }
      grid.addArrangedSubview(stack)
    }

    // Bottom: one continuous “0” band + a same-height 完成 key in the side column.
    let bottom = makeRow()
    bottom.distribution = .fill
    let zero = makeKey(title: "0", kind: .digit) { [weak self] in self?.onInsert?("0") }
    let done = makeKey(title: L10n.text(.sheetDone), kind: .done) { [weak self] in
      self?.onDone?()
    }
    bottom.addArrangedSubview(zero)
    bottom.addArrangedSubview(done)
    // Side column width = 1/4 of row (matches ⌫ / − / . above).
    done.widthAnchor.constraint(
      equalTo: bottom.widthAnchor,
      multiplier: 0.25,
      constant: -keyGap * 0.75
    ).isActive = true
    grid.addArrangedSubview(bottom)

    setNeedsLayout()
  }

  private func handleSide(_ kind: KeyKind) {
    switch kind {
    case .delete: onDelete?()
    case .sign: onToggleSign?()
    case .digit, .done, .spacer, .muted: break
    }
  }

  private enum KeyKind {
    case digit, delete, sign, done, spacer, muted
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let caret = caretHeight
    if caretPointsUp {
      chrome.frame = CGRect(x: 0, y: caret, width: bounds.width, height: bounds.height - caret)
    } else {
      chrome.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - caret)
    }
    let content = chrome.bounds.insetBy(dx: chromePad, dy: chromePad)
    grid.frame = content
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    // Slim caret toward the text field (matches paper chrome).
    let midX = bounds.midX
    let path = UIBezierPath()
    let c = caretHeight
    if caretPointsUp {
      path.move(to: CGPoint(x: midX - 8, y: c))
      path.addLine(to: CGPoint(x: midX + 8, y: c))
      path.addLine(to: CGPoint(x: midX, y: 0.5))
    } else {
      let y = bounds.height - c
      path.move(to: CGPoint(x: midX - 8, y: y))
      path.addLine(to: CGPoint(x: midX + 8, y: y))
      path.addLine(to: CGPoint(x: midX, y: bounds.height - 0.5))
    }
    path.close()
    Self.paper.setFill()
    path.fill()
    // Hairline on caret edges for definition on paper background.
    Self.hairline.setStroke()
    path.lineWidth = 0.5
    path.stroke()
  }

  private func makeRow() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = keyGap
    stack.distribution = .fillEqually
    return stack
  }

  private func makeSpacer() -> UIView {
    let v = UIView()
    v.isUserInteractionEnabled = false
    v.backgroundColor = .clear
    return v
  }

  private func makeKey(title: String, kind: KeyKind, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.layer.cornerRadius = 8
    button.layer.cornerCurve = .continuous
    button.clipsToBounds = true
    button.layer.borderWidth = 0.5
    button.layer.borderColor = Self.hairline.cgColor
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)

    // All keys share the same paper face so “完成” is not a foreign blue slab.
    button.backgroundColor = Self.keyFace

    switch kind {
    case .done:
      // Same ink as digit keys — no accent color callout.
      button.setTitle(title, for: .normal)
      button.setTitleColor(Self.ink, for: .normal)
      button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    case .delete:
      let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
      button.setImage(UIImage(systemName: "delete.left", withConfiguration: config), for: .normal)
      button.tintColor = Self.muted
    case .sign:
      button.setTitle(title, for: .normal)
      button.setTitleColor(Self.ink, for: .normal)
      button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
    case .digit:
      button.setTitle(title, for: .normal)
      button.setTitleColor(Self.ink, for: .normal)
      button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
    case .muted:
      button.setTitle(title, for: .normal)
      button.setTitleColor(Self.muted.withAlphaComponent(0.45), for: .normal)
      button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .regular)
      button.isEnabled = false
      button.layer.borderColor = UIColor.clear.cgColor
      button.backgroundColor = Self.keyFace.withAlphaComponent(0.55)
    case .spacer:
      button.backgroundColor = .clear
      button.layer.borderWidth = 0
      button.isUserInteractionEnabled = false
    }

    if kind != .spacer && kind != .muted {
      button.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
      button.addTarget(self, action: #selector(keyTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    return button
  }

  @objc private func keyTouchDown(_ sender: UIButton) {
    sender.backgroundColor = Self.keyPressed
  }

  @objc private func keyTouchUp(_ sender: UIButton) {
    sender.backgroundColor = Self.keyFace
  }
}

/// True iOS `UITextField` decimal box: free cursor placement, digits-only draft,
/// single commit on Done / focus loss (never per-keystroke model updates).
/// System keyboard is suppressed; `QixiFloatingDecimalPad` sits exactly above the field.
struct QixiDecimalNumberField: UIViewRepresentable {
  var committedValue: Double
  var fractionDigits: Int
  var range: ClosedRange<Double>
  var allowsNegative: Bool
  var accessibilityLabel: String
  var onCommit: (Double) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> UITextField {
    let field = UITextField(frame: .zero)
    field.delegate = context.coordinator
    // Avoid .decimalPad — on iPad it can still spawn a floating system pad even with
    // a custom inputView. asciiCapable + zero-height UIInputView fully suppresses it.
    field.keyboardType = .asciiCapable
    field.inputView = QixiFloatingDecimalPad.makeSuppressedInputView()
    field.inputAccessoryView = nil
    field.inputAssistantItem.leadingBarButtonGroups = []
    field.inputAssistantItem.trailingBarButtonGroups = []
    field.textAlignment = .right
    field.borderStyle = .none
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.smartDashesType = .no
    field.smartQuotesType = .no
    field.smartInsertDeleteType = .no
    field.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold)
    field.textColor = UIColor(QixiColor.ink)
    field.backgroundColor = UIColor.white.withAlphaComponent(0.55)
    field.layer.cornerRadius = 6
    field.clipsToBounds = true
    field.setContentHuggingPriority(.required, for: .horizontal)
    field.setContentCompressionResistancePriority(.required, for: .horizontal)
    let pad = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 1))
    field.leftView = pad
    field.leftViewMode = .always
    field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 1))
    field.rightViewMode = .always
    field.accessibilityLabel = accessibilityLabel
    context.coordinator.field = field
    context.coordinator.syncTextFromCommitted(force: true)
    field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged), for: .editingChanged)
    return field
  }

  func updateUIView(_ field: UITextField, context: Context) {
    context.coordinator.parent = self
    field.accessibilityLabel = accessibilityLabel
    // Keep suppression installed (SwiftUI updates can clear inputView).
    if !(field.inputView is UIInputView) {
      field.inputView = QixiFloatingDecimalPad.makeSuppressedInputView()
      field.inputAccessoryView = nil
    }
    if !field.isFirstResponder {
      context.coordinator.syncTextFromCommitted(force: false)
    } else {
      // Keep the single pad glued above the field if layout moved.
      DispatchQueue.main.async {
        QixiFloatingDecimalPad.reposition(animated: false)
      }
    }
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: QixiDecimalNumberField
    weak var field: UITextField?
    private var draft: String = ""
    private var lastCommittedDisplay: String = ""

    init(parent: QixiDecimalNumberField) {
      self.parent = parent
    }

    func syncTextFromCommitted(force: Bool) {
      let display = Self.format(parent.committedValue, fractionDigits: parent.fractionDigits)
      if force || display != lastCommittedDisplay {
        draft = display
        lastCommittedDisplay = display
        field?.text = display
      }
    }

    @objc func editingChanged() {
      draft = field?.text ?? ""
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
      draft = textField.text ?? ""
      textField.inputView = QixiFloatingDecimalPad.makeSuppressedInputView()
      textField.inputAccessoryView = nil
      textField.inputAssistantItem.leadingBarButtonGroups = []
      textField.inputAssistantItem.trailingBarButtonGroups = []
      textField.reloadInputViews()
      // Present after the field is in the hierarchy / has a window.
      DispatchQueue.main.async {
        QixiFloatingDecimalPad.present(for: textField, allowsNegative: self.parent.allowsNegative)
      }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
      let cancelled = QixiFloatingDecimalPad.consumeCancelOnEndEditing()
      if cancelled {
        // Outside-tap: restore pre-edit value, do not push to the ViewModel.
        syncTextFromCommitted(force: true)
      } else {
        commitDraft()
      }
      QixiFloatingDecimalPad.detach(field: textField)
    }

    func textField(
      _ textField: UITextField,
      shouldChangeCharactersIn range: NSRange,
      replacementString string: String
    ) -> Bool {
      let current = textField.text ?? ""
      guard let swiftRange = Range(range, in: current) else { return false }
      let proposed = current.replacingCharacters(in: swiftRange, with: string)
      return Self.isValidDraft(
        proposed,
        fractionDigits: parent.fractionDigits,
        allowsNegative: parent.allowsNegative
      )
    }

    private func commitDraft() {
      let raw = (field?.text ?? draft)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
      guard let parsed = Double(raw), parsed.isFinite else {
        syncTextFromCommitted(force: true)
        return
      }
      let scale = pow(10.0, Double(max(0, parent.fractionDigits)))
      let rounded = (parsed * scale).rounded() / scale
      let clamped = min(max(rounded, parent.range.lowerBound), parent.range.upperBound)
      let display = Self.format(clamped, fractionDigits: parent.fractionDigits)
      draft = display
      lastCommittedDisplay = display
      field?.text = display
      parent.onCommit(clamped)
    }

    static func format(_ value: Double, fractionDigits: Int) -> String {
      let formatter = NumberFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = 0
      formatter.maximumFractionDigits = fractionDigits
      formatter.usesGroupingSeparator = false
      return formatter.string(from: NSNumber(value: value))
        ?? String(format: "%.\(fractionDigits)f", value)
    }

    static func isValidDraft(_ text: String, fractionDigits: Int, allowsNegative: Bool) -> Bool {
      if text.isEmpty { return true }
      var index = text.startIndex
      if text[index] == "-" {
        guard allowsNegative else { return false }
        index = text.index(after: index)
        if index == text.endIndex { return true }
      }
      var sawDot = false
      var fractionCount = 0
      while index < text.endIndex {
        let ch = text[index]
        if ch == "." {
          if sawDot { return false }
          sawDot = true
        } else if ch >= "0" && ch <= "9" {
          if sawDot {
            fractionCount += 1
            if fractionCount > fractionDigits { return false }
          }
        } else {
          return false
        }
        index = text.index(after: index)
      }
      return true
    }
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
      UtilityButton(title: L10n.text(.utilityImport), systemName: "folder") {
        model.openUtilitySheet(.importGame)
      }
      UtilityButton(title: L10n.text(.utilitySync), systemName: "square.and.arrow.down") {
        model.openUtilitySheet(.sync)
      }
      UtilityButton(title: L10n.text(.utilityExportShare), systemName: "square.and.arrow.up") {
        model.openUtilitySheet(.exportShare)
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
