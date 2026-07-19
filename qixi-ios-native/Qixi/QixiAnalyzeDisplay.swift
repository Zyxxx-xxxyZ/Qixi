import Foundation
import SwiftUI
import Combine

/// Lock-free analyze plane payload (mirrors packed C++ `AnalyzeDisplayPayload`).
struct QixiAnalyzeDisplayPayload: Equatable {
  static let maxCandidates = 10
  static let boardArea = 361
  /// Packed size must match core `sizeof(AnalyzeDisplayPayload)`.
  static let packedByteCount =
    8 + 8 + 4 + 4 + 8 + 4 + 4 + 14 * maxCandidates + 4 * boardArea + 1

  var backendEpoch: UInt64 = 0
  var revision: UInt64 = 0
  var root: UInt32 = 0
  var candidateCount: UInt32 = 0
  var rootVisits: UInt64 = 0
  var rootWinrate: Double = 0.5
  var rootScoreMean: Double = 0.0
  var candidates: [Cand] = []
  /// Fixed 361 ownership values (side-to-move polarity as published by core).
  var ownership: [Float] = Array(repeating: 0, count: boardArea)
  var hasOwnership: Bool = false

  struct Cand: Equatable {
    var move: UInt16
    var visits: UInt32
    var winrate: Float
    var scoreMean: Float

    var isPass: Bool { move >= 361 }
    var x: Int { Int(move % 19) }
    var y: Int { Int(move / 19) }
  }

  static func decode(from data: Data) -> QixiAnalyzeDisplayPayload? {
    guard data.count >= packedByteCount else { return nil }
    return data.withUnsafeBytes { raw -> QixiAnalyzeDisplayPayload? in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
      var offset = 0
      func loadU64() -> UInt64 {
        let v = base.advanced(by: offset).withMemoryRebound(to: UInt64.self, capacity: 1) { $0.pointee }
        offset += 8
        return v
      }
      func loadU32() -> UInt32 {
        let v = base.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        offset += 4
        return v
      }
      func loadF32() -> Float {
        let v = base.advanced(by: offset).withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
        offset += 4
        return v
      }
      func loadU16() -> UInt16 {
        let v = base.advanced(by: offset).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
        offset += 2
        return v
      }

      var payload = QixiAnalyzeDisplayPayload()
      payload.backendEpoch = loadU64()
      payload.revision = loadU64()
      payload.root = loadU32()
      payload.candidateCount = loadU32()
      payload.rootVisits = loadU64()
      payload.rootWinrate = Double(loadF32())
      payload.rootScoreMean = Double(loadF32())

      let count = min(Int(payload.candidateCount), maxCandidates)
      payload.candidates.reserveCapacity(count)
      for _ in 0..<maxCandidates {
        let move = loadU16()
        let visits = loadU32()
        let wr = loadF32()
        let sm = loadF32()
        if payload.candidates.count < count {
          payload.candidates.append(Cand(move: move, visits: visits, winrate: wr, scoreMean: sm))
        }
      }

      var ownership = [Float](repeating: 0, count: boardArea)
      for i in 0..<boardArea {
        ownership[i] = loadF32()
      }
      payload.ownership = ownership
      payload.hasOwnership = base.advanced(by: offset).pointee != 0
      return payload
    }
  }
}

/// Next-move presentation layered on top of the lock-free HUD candidate set.
struct QixiNextMoveDecoration: Equatable {
  var x: Int
  var y: Int
  var color: StoneColor
  /// True when the next move has been sampled/analyzed (current-root visits or child analysis).
  var isSampled: Bool
  /// Metrics used when the sampled next move is outside the normal display set.
  var forcedRankText: String = ">"
  var forcedWinrate: Double?
  var forcedVisits: Int?
  var forcedScoreMean: Double?
  var forcedColorComponents: CandidateColorComponents?

  var pointID: Int { y * 19 + x }
}

/// Tiny ObservableObject for analyze overlays only (not board / chrome).
@MainActor
final class QixiAnalyzeDisplayModel: ObservableObject {
  static let maxDisplayCandidates = 10

  @Published private(set) var revision: UInt64 = 0
  @Published private(set) var rootWinrate: Double = 0.5
  @Published private(set) var rootScoreMean: Double = 0.0
  @Published private(set) var rootVisits: UInt64 = 0
  @Published private(set) var overlays: [VisibleCandidateOverlay] = []
  /// Fixed ownership grid; empty when unavailable.
  @Published private(set) var ownership: [Float] = []
  @Published private(set) var hasOwnership: Bool = false

  private var lastRevision: UInt64 = 0
  /// HUD/base candidates before next-move decoration.
  private var baseOverlays: [VisibleCandidateOverlay] = []
  private var nextMoveDecoration: QixiNextMoveDecoration?
  /// Sampled (visits > 0) candidates from the latest HUD payload, including those
  /// filtered out of the normal winrate display window — used to force-show next move.
  private var sampledHUDMetricsByPointID: [Int: SampledHUDCandidate] = [:]
  /// Pass is filtered out of board overlays; keep its sampled metrics for variation-tree dye.
  private(set) var sampledPassMetrics: SampledHUDCandidate?

  /// Enter/exit presentation: keep fading slots so candidates that join/leave the
  /// display window animate through a color gradient instead of popping.
  private struct PresentationSlot {
    var overlay: VisibleCandidateOverlay
    /// Current 0…1 weight (animated).
    var weight: Double
    /// 1 while still in the live analysis set; 0 while exiting.
    var targetWeight: Double
  }

  private var presentationSlots: [Int: PresentationSlot] = [:]
  private var transitionTask: Task<Void, Never>?
  /// ~280 ms enter / ~320 ms exit at 60 Hz ticks.
  private static let enterRatePerSecond = 1.0 / 0.28
  private static let exitRatePerSecond = 1.0 / 0.32

  struct SampledHUDCandidate: Equatable {
    var x: Int
    var y: Int
    var rank: Int
    var visits: Int
    var winrate: Double
    var scoreMean: Double
    var colorComponents: CandidateColorComponents
  }

  func apply(_ payload: QixiAnalyzeDisplayPayload) {
    guard payload.revision != lastRevision else { return }
    lastRevision = payload.revision
    // Batch @Published updates: only assign when values actually change.
    if revision != payload.revision { revision = payload.revision }
    if rootWinrate != payload.rootWinrate { rootWinrate = payload.rootWinrate }
    if rootScoreMean != payload.rootScoreMean { rootScoreMean = payload.rootScoreMean }
    if rootVisits != payload.rootVisits { rootVisits = payload.rootVisits }

    // Display at most 10 non-pass candidates within the normal winrate window.
    // Filter passes first so a pass slot does not drop a real move from the top-K window.
    // Still keep sampled pass metrics so the variation tree can dye pass steps.
    if let passCand = payload.candidates.first(where: { $0.isPass && $0.visits > 0 }) {
      let passWR = Double(passCand.winrate)
      let passScore = Double(passCand.scoreMean)
      // Peers = all visited board moves + pass so extreme-low score mode applies to pass too.
      var peerWR: [Double] = []
      var peerSC: [Double] = []
      for cand in payload.candidates where cand.visits > 0 {
        peerWR.append(Double(cand.winrate))
        peerSC.append(Double(cand.scoreMean))
      }
      let delta = CandidatePalette.qualityDeltaPercent(
        winrate: passWR,
        scoreMean: passScore,
        peerWinrates: peerWR,
        peerScores: peerSC,
        positionSideToMoveWinrate: payload.rootWinrate
      ) ?? 0.0
      sampledPassMetrics = SampledHUDCandidate(
        x: -1,
        y: -1,
        rank: 0,
        visits: Int(clamping: passCand.visits),
        winrate: passWR,
        scoreMean: passScore,
        colorComponents: CandidatePalette.components(deltaPercent: delta)
      )
    } else {
      sampledPassMetrics = nil
    }
    let displayCandidates = Array(
      payload.candidates.lazy.filter { !$0.isPass }.prefix(Self.maxDisplayCandidates)
    )
    let layoutItems = displayCandidates.enumerated().map { index, cand in
      CandidateQualityLayout.Item(
        x: cand.x,
        y: cand.y,
        visits: Int(clamping: cand.visits),
        winrate: Double(cand.winrate),
        scoreMean: Double(cand.scoreMean),
        sourceIndex: index
      )
    }
    // Root STM winrate: extreme-low is "side to move ≤ 5%", not Black ≤ 5%.
    let (_, ranked) = CandidateQualityLayout.layout(
      layoutItems,
      positionSideToMoveWinrate: payload.rootWinrate
    )
    var nextOverlays: [VisibleCandidateOverlay] = []
    nextOverlays.reserveCapacity(ranked.count)
    var sampledMetrics: [Int: SampledHUDCandidate] = [:]
    for item in ranked {
      let pointID = item.y * 19 + item.x
      sampledMetrics[pointID] = SampledHUDCandidate(
        x: item.x,
        y: item.y,
        rank: item.rank,
        visits: item.visits,
        winrate: item.winrate,
        scoreMean: item.scoreMean,
        colorComponents: item.colorComponents
      )
      nextOverlays.append(
        VisibleCandidateOverlay(
          x: item.x,
          y: item.y,
          rankText: String(item.rank),
          winrateText: NumberText.winrate(item.winrate),
          visitsText: String(item.visits),
          scoreText: NumberText.score(item.scoreMean),
          colorComponents: item.colorComponents
        )
      )
    }
    sampledHUDMetricsByPointID = sampledMetrics
    baseOverlays = nextOverlays
    republishOverlays()

    // Ownership: blend toward the latest grid so the heatmap eases instead of
    // hard-snapping every sample (and no sparse “skip 11 frames” gate).
    if payload.hasOwnership {
      let incoming = payload.ownership
      if !hasOwnership || ownership.count != incoming.count {
        ownership = incoming
        hasOwnership = true
      } else {
        var blended = ownership
        // ~1/3 of the remaining gap per HUD apply → smooth settle without lagging far.
        let blend: Float = 0.34
        var changed = false
        for i in blended.indices {
          let next = blended[i] + (incoming[i] - blended[i]) * blend
          if abs(next - blended[i]) > 2e-4 { changed = true }
          blended[i] = next
        }
        if changed {
          ownership = blended
        }
      }
    } else if hasOwnership {
      hasOwnership = false
      ownership = []
    }
  }

  /// Sampled HUD metrics for a board point (even if outside the normal display window).
  func sampledHUDCandidate(atPointID pointID: Int) -> SampledHUDCandidate? {
    sampledHUDMetricsByPointID[pointID]
  }

  /// Merge next-move outline/ring decoration into the published overlay set.
  func setNextMoveDecoration(_ decoration: QixiNextMoveDecoration?) {
    guard decoration != nextMoveDecoration else { return }
    nextMoveDecoration = decoration
    republishOverlays()
  }

  /// Show cached analysis on the board immediately after navigation (no lock-free HUD yet).
  /// Resets revision so the next live HUD payload is always accepted.
  func applyCached(
    winrate: Double,
    scoreMean: Double,
    visits: Int,
    candidates: [CandidateMove],
    territory: [TerritoryPoint]
  ) {
    lastRevision = 0
    revision = 0
    rootWinrate = winrate
    rootScoreMean = scoreMean
    rootVisits = UInt64(max(0, visits))

    let displayCandidates = Array(candidates.prefix(Self.maxDisplayCandidates))
    let layoutItems = displayCandidates.enumerated().map { index, cand in
      CandidateQualityLayout.Item(
        x: cand.x,
        y: cand.y,
        visits: cand.visits,
        winrate: cand.winrate,
        scoreMean: cand.scoreMean,
        sourceIndex: index
      )
    }
    let (_, ranked) = CandidateQualityLayout.layout(
      layoutItems,
      positionSideToMoveWinrate: winrate
    )
    var nextOverlays: [VisibleCandidateOverlay] = []
    nextOverlays.reserveCapacity(ranked.count)
    var sampledMetrics: [Int: SampledHUDCandidate] = [:]
    for item in ranked {
      sampledMetrics[item.y * 19 + item.x] = SampledHUDCandidate(
        x: item.x,
        y: item.y,
        rank: item.rank,
        visits: item.visits,
        winrate: item.winrate,
        scoreMean: item.scoreMean,
        colorComponents: item.colorComponents
      )
      nextOverlays.append(
        VisibleCandidateOverlay(
          x: item.x,
          y: item.y,
          rankText: String(item.rank),
          winrateText: NumberText.winrate(item.winrate),
          visitsText: String(item.visits),
          scoreText: NumberText.score(item.scoreMean),
          colorComponents: item.colorComponents
        )
      )
    }
    sampledHUDMetricsByPointID = sampledMetrics
    baseOverlays = nextOverlays
    republishOverlays()

    if territory.isEmpty {
      hasOwnership = false
      ownership = []
    } else {
      var grid = [Float](repeating: 0, count: QixiAnalyzeDisplayPayload.boardArea)
      for point in territory {
        let index = point.y * 19 + point.x
        guard index >= 0, index < grid.count else { continue }
        grid[index] = Float(point.ownership)
      }
      ownership = grid
      hasOwnership = true
    }
  }

  func clear() {
    lastRevision = 0
    revision = 0
    rootWinrate = 0.5
    rootScoreMean = 0.0
    rootVisits = 0
    baseOverlays = []
    nextMoveDecoration = nil
    sampledHUDMetricsByPointID = [:]
    sampledPassMetrics = nil
    presentationSlots = [:]
    transitionTask?.cancel()
    transitionTask = nil
    overlays = []
    ownership = []
    hasOwnership = false
  }

  private func republishOverlays() {
    let merged = Self.mergeNextMove(into: baseOverlays, decoration: nextMoveDecoration)
    reconcilePresentation(with: merged)
  }

  /// Diff live analysis set against presentation slots: enter from weight 0, exit to 0.
  private func reconcilePresentation(with live: [VisibleCandidateOverlay]) {
    let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })

    for id in presentationSlots.keys {
      if let liveOverlay = liveByID[id] {
        presentationSlots[id]?.overlay = liveOverlay
        presentationSlots[id]?.targetWeight = 1.0
      } else {
        // Still paint while fading out (last known metrics + color).
        presentationSlots[id]?.targetWeight = 0.0
      }
    }

    for (id, overlay) in liveByID {
      if presentationSlots[id] == nil {
        // Next-move stone outlines (no analysis fill) must appear immediately —
        // under "no engine" they are the only board cue. Fading them from weight 0
        // left black/white strokes invisible until the ticker ran (or forever if
        // the ticker was cancelled by a concurrent clear).
        let startWeight = overlay.usesStoneSizedContinuationMarker ? 1.0 : 0.0
        presentationSlots[id] = PresentationSlot(
          overlay: overlay,
          weight: startWeight,
          targetWeight: 1.0
        )
      }
    }

    publishPresentationOverlays()
    if presentationNeedsAnimation {
      ensureTransitionTicker()
    }
  }

  private var presentationNeedsAnimation: Bool {
    presentationSlots.values.contains { abs($0.weight - $0.targetWeight) > 0.01 }
  }

  private func ensureTransitionTicker() {
    guard transitionTask == nil else { return }
    transitionTask = Task { @MainActor [weak self] in
      defer { self?.transitionTask = nil }
      while !Task.isCancelled {
        guard let self else { return }
        let stillAnimating = self.stepPresentationWeights(dt: 1.0 / 60.0)
        self.publishPresentationOverlays()
        if !stillAnimating { return }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }

  /// Advance enter/exit weights. Returns true while any slot is still mid-transition.
  @discardableResult
  private func stepPresentationWeights(dt: Double) -> Bool {
    let clampedDt = min(0.05, max(0.001, dt))
    var anyActive = false
    var finishedExits: [Int] = []

    for (id, var slot) in presentationSlots {
      let target = slot.targetWeight
      if abs(slot.weight - target) <= 0.01 {
        slot.weight = target
        if target <= 0.0 {
          finishedExits.append(id)
        }
      } else if slot.weight < target {
        slot.weight = min(target, slot.weight + Self.enterRatePerSecond * clampedDt)
        anyActive = true
      } else {
        slot.weight = max(target, slot.weight - Self.exitRatePerSecond * clampedDt)
        anyActive = true
        if slot.weight <= 0.01 && target <= 0.0 {
          finishedExits.append(id)
        }
      }
      presentationSlots[id] = slot
    }

    for id in finishedExits {
      presentationSlots.removeValue(forKey: id)
    }
    return anyActive || presentationNeedsAnimation
  }

  private func publishPresentationOverlays() {
    var next: [VisibleCandidateOverlay] = []
    next.reserveCapacity(presentationSlots.count)
    // Stable order: by rank text then point id (matches visual top-left scanning).
    let ordered = presentationSlots.values.sorted {
      if $0.overlay.rankText != $1.overlay.rankText {
        return $0.overlay.rankText < $1.overlay.rankText
      }
      return $0.overlay.id < $1.overlay.id
    }
    for slot in ordered {
      guard slot.weight > 0.01 else { continue }
      var overlay = slot.overlay
      overlay.presentationWeight = slot.weight
      // Hide analysis text until mostly faded in (exit hides earlier).
      if slot.weight < 0.45 {
        overlay.showsAnalysisText = false
      }
      next.append(overlay)
    }
    if next != overlays {
      overlays = next
    }
  }

  /// Pure merge used by the display model (and unit-testable).
  static func mergeNextMove(
    into base: [VisibleCandidateOverlay],
    decoration: QixiNextMoveDecoration?
  ) -> [VisibleCandidateOverlay] {
    guard let decoration else { return base }
    var result = base
    result.reserveCapacity(base.count + 1)
    let pointID = decoration.pointID

    if let index = result.firstIndex(where: { $0.id == pointID }) {
      // Already in the normal analysis set → thin stone-color ring on the disk edge.
      result[index].continuationRingColor = decoration.color
      result[index].usesStoneSizedContinuationMarker = false
      result[index].showsAnalysisText = true
      return result
    }

    if !decoration.isSampled {
      // Known next move, not yet sampled → faint stone-sized outline only.
      result.append(
        VisibleCandidateOverlay(
          x: decoration.x,
          y: decoration.y,
          rankText: "",
          winrateText: "",
          visitsText: "",
          scoreText: "",
          colorComponents: nil,
          continuationRingColor: decoration.color,
          showsAnalysisText: false,
          usesStoneSizedContinuationMarker: true
        )
      )
      return result
    }

    // Sampled but outside normal display range → force-show analysis disk + ring.
    guard
      let visits = decoration.forcedVisits, visits > 0,
      let winrate = decoration.forcedWinrate,
      let scoreMean = decoration.forcedScoreMean
    else {
      return result
    }
    result.append(
      VisibleCandidateOverlay(
        x: decoration.x,
        y: decoration.y,
        rankText: decoration.forcedRankText,
        winrateText: NumberText.winrate(winrate),
        visitsText: String(visits),
        scoreText: NumberText.score(scoreMean),
        colorComponents: decoration.forcedColorComponents ?? CandidatePalette.unknownAnalysisComponents,
        continuationRingColor: decoration.color,
        showsAnalysisText: true,
        usesStoneSizedContinuationMarker: false
      )
    )
    return result
  }
}
