import SwiftUI

/// Shared policy for candidate dye / rank / display-window.
///
/// ## Normal mode (winrate loss)
/// Let `W*` be the highest absolute winrate among non-pass candidates with visits > 0.
/// For each candidate with winrate `W`:
///   `k = (W − W*) × 100`   // percentage points; 0 = best, negative = worse
/// Rank order: engine visit order (top-K), display only if `k > −5`.
/// Color: `components(deltaPercent: k)` (see green→yellow→orange→red map below).
///
/// ## Extreme-low mode (score loss)
/// When the **side to move** has winrate ≤ 5% (not “Black’s winrate ≤ 5%”),
/// winrate deltas become noise (every move looks equally dead). Then:
/// Let `S*` be the highest **side-to-move** `scoreMean` among those candidates.
/// For each candidate with score `S`:
///   `k_score = S* − S`     // points behind best; 0 = best, positive = worse
/// Palette k = `−k_score × scoreLossPaletteScale` so a few points of score lead
/// actually leave the all-green band (raw 1:1 left 0–3 pt spreads invisible).
/// Rank order: score descending (best score = rank 1).
/// **Cut-off:** show only if score loss `< scoreDisplayWindowPoints` (default 5 pts
/// behind best) — score-based analogue of the normal −5% winrate window.
///
/// Equivalence: Black chart winrate ≥ 95% with White to play ⇔ White STM ≤ 5%
/// ⇔ extreme-low score-loss dyeing + score cut-off of White’s candidates.
enum CandidatePalette {
  /// Side-to-move winrate at/below which a position is "extreme low".
  static let extremeLowWinrateAbsolute = 0.05
  /// Display-window half-width in winrate-loss mode (percentage points vs best).
  static let winrateDisplayWindowPercent = 5.0
  /// Extreme-low display window: hide moves more than this many **score points**
  /// behind the best side-to-move score (parallel to −5% winrate cut-off).
  static let scoreDisplayWindowPoints = 5.0
  /// Map score-lead points → palette units (same curve as winrate percentage points).
  /// ~1.2 score points ≈ leave pure green (−3); ~2 points ≈ yellow edge (−5).
  static let scoreLossPaletteScale = 2.5

  static let unknownAnalysisComponents = CandidateColorComponents(
    red: 0.470,
    green: 0.494,
    blue: 0.548,
    alpha: 0.58
  )
  static let unknownAnalysisColor = unknownAnalysisComponents.color

  /// How k is computed for a candidate set (winrate loss vs score loss).
  enum QualityMode: Equatable {
    /// k = (winrate − bestWinrate) × 100
    case winrateLoss(bestWinrate: Double)
    /// k = −(bestScore − scoreMean) × scoreLossPaletteScale
    case scoreLoss(bestScore: Double)
  }

  /// Side-to-move winrate ≤ 5% (crushed).
  static func isExtremeLowSideToMove(winrate: Double) -> Bool {
    winrate.isFinite && winrate <= extremeLowWinrateAbsolute
  }

  /// Effective STM winrate for extreme-low gating: prefer the more hopeless signal
  /// between the position eval and the best peer move (avoids mode flicker when one
  /// optimistic candidate sits just above 5% while the root is still ≤ 5%).
  static func effectiveSideToMoveWinrate(
    bestPeerWinrate: Double,
    positionSideToMoveWinrate: Double?
  ) -> Double {
    guard let position = positionSideToMoveWinrate, position.isFinite else {
      return bestPeerWinrate
    }
    guard bestPeerWinrate.isFinite else { return position }
    return min(bestPeerWinrate, position)
  }

  /// Convert Black-absolute metrics to side-to-move polarity for dyeing.
  static func sideToMoveMetrics(
    blackWinrate: Double,
    blackScoreMean: Double,
    sideToMove: StoneColor
  ) -> (winrate: Double, scoreMean: Double) {
    if sideToMove == .black {
      return (blackWinrate, blackScoreMean)
    }
    return (1.0 - blackWinrate, -blackScoreMean)
  }

  /// Normalize peer metrics to **side-to-move** polarity for dyeing.
  /// When the position STM winrate is ≤ 5% but peer winrates look ≥ 95% (Black-absolute
  /// or inverted), flip peers so White-to-move crushed positions enter score-loss mode.
  static func normalizedSideToMovePeers(
    winrates: [Double],
    scores: [Double],
    positionSideToMoveWinrate: Double? = nil
  ) -> (winrates: [Double], scores: [Double], flipped: Bool) {
    guard winrates.count == scores.count, let bestPeer = winrates.max() else {
      return (winrates, scores, false)
    }
    if let positionWR = positionSideToMoveWinrate,
       positionWR.isFinite,
       isExtremeLowSideToMove(winrate: positionWR),
       bestPeer >= 1.0 - extremeLowWinrateAbsolute {
      return (winrates.map { 1.0 - $0 }, scores.map { -$0 }, true)
    }
    return (winrates, scores, false)
  }

  /// Choose mode from **side-to-move** peer winrates/scores.
  /// - `winrates` / `scores`: side-to-move polarity (core convention).
  /// - `positionSideToMoveWinrate`: root / position STM winrate when available; used so a
  ///   few optimistic candidates cannot keep the palette in winrate-loss mode while the
  ///   side to move is still ≤ 5% (e.g. Black chart ≥ 95% with White to play).
  static func qualityMode(
    winrates: [Double],
    scores: [Double],
    positionSideToMoveWinrate: Double? = nil
  ) -> QualityMode? {
    guard !winrates.isEmpty, winrates.count == scores.count else { return nil }
    let normalized = normalizedSideToMovePeers(
      winrates: winrates,
      scores: scores,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    )
    guard let bestWinrate = normalized.winrates.max() else { return nil }
    // Side-to-move crushed ⇔ effective STM ≤ 5% (root and/or best peer).
    // Black chart ≥ 95% with White to play ⇔ White STM ≤ 5% ⇔ score-loss dyeing.
    let effectiveSTM = effectiveSideToMoveWinrate(
      bestPeerWinrate: bestWinrate,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    )
    if isExtremeLowSideToMove(winrate: effectiveSTM) {
      guard let bestScore = normalized.scores.max() else { return nil }
      return .scoreLoss(bestScore: bestScore)
    }
    return .winrateLoss(bestWinrate: bestWinrate)
  }

  /// Palette / tree k (≤ 0 for worse moves). Same polarity in both modes.
  /// `winrate` / `scoreMean` must match the side-to-move polarity used for `mode`.
  static func paletteDeltaK(
    winrate: Double,
    scoreMean: Double,
    mode: QualityMode
  ) -> Double {
    switch mode {
    case .winrateLoss(let best):
      return (winrate - best) * 100.0
    case .scoreLoss(let bestScore):
      // Points behind best (STM score lead). Scale into winrate-% palette space so
      // typical 1–3 pt spreads actually leave the green band.
      let scoreLoss = max(0.0, bestScore - scoreMean)
      return -scoreLoss * scoreLossPaletteScale
    }
  }

  /// User-facing score loss in points (only meaningful in score mode); 0 = best.
  static func scoreLoss(
    scoreMean: Double,
    mode: QualityMode
  ) -> Double? {
    guard case .scoreLoss(let bestScore) = mode else { return nil }
    return max(0.0, bestScore - scoreMean)
  }

  /// One-shot quality k for a move against a peer set (board + tree + pass dye).
  /// Peers should be visited candidates at the same root (non-pass and/or pass),
  /// in **side-to-move** polarity. Optional `positionSideToMoveWinrate` is the root STM WR.
  static func qualityDeltaPercent(
    winrate: Double,
    scoreMean: Double,
    peerWinrates: [Double],
    peerScores: [Double],
    positionSideToMoveWinrate: Double? = nil
  ) -> Double? {
    guard peerWinrates.count == peerScores.count, !peerWinrates.isEmpty else { return nil }
    let normalized = normalizedSideToMovePeers(
      winrates: peerWinrates,
      scores: peerScores,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    )
    let wr = normalized.flipped ? (1.0 - winrate) : winrate
    let sc = normalized.flipped ? -scoreMean : scoreMean
    guard let mode = qualityMode(
      winrates: normalized.winrates,
      scores: normalized.scores,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    ) else { return nil }
    return paletteDeltaK(winrate: wr, scoreMean: sc, mode: mode)
  }

  /// Palette-k cut-off for the display window (exclusive lower bound: show if `k > cut`).
  /// - Winrate-loss: −5 (percentage points vs best).
  /// - Score-loss: −(scoreDisplayWindowPoints × scoreLossPaletteScale)
  ///   so score loss of `scoreDisplayWindowPoints` maps to the window edge.
  static func displayWindowCutoffK(for mode: QualityMode) -> Double {
    switch mode {
    case .winrateLoss:
      return -winrateDisplayWindowPercent
    case .scoreLoss:
      return -scoreDisplayWindowPoints * scoreLossPaletteScale
    }
  }

  /// Whether a candidate is inside the board display set.
  /// Winrate-loss: within 5% of best. Score-loss (STM ≤ 5%): within 5 score points of best.
  static func isInDisplayWindow(paletteDeltaK k: Double, mode: QualityMode) -> Bool {
    k > displayWindowCutoffK(for: mode)
  }

  /// Score-points behind best for a given palette k in score-loss mode.
  static func scoreLossPoints(paletteDeltaK k: Double) -> Double {
    // k = -scoreLoss * scale  ⇒  scoreLoss = -k / scale
    guard scoreLossPaletteScale > 0 else { return 0 }
    return max(0.0, -k / scoreLossPaletteScale)
  }

  /// Sort key for ranking: lower is better (rank 1 first).
  static func rankSortKey(
    winrate: Double,
    scoreMean: Double,
    visits: Int,
    mode: QualityMode
  ) -> (Double, Int) {
    switch mode {
    case .winrateLoss:
      // Preserve visit-priority among equals: higher visits first via negative visits.
      return (-winrate, -visits)
    case .scoreLoss:
      return (-scoreMean, -visits)
    }
  }

  static func color(deltaPercent k: Double) -> Color {
    components(deltaPercent: k).color
  }

  /// Display-window edge color for enter/exit fades (defaults to winrate −5% edge).
  static var displayThresholdComponents: CandidateColorComponents {
    displayThresholdComponents(for: .winrateLoss(bestWinrate: 0))
  }

  static func displayThresholdComponents(for mode: QualityMode) -> CandidateColorComponents {
    components(deltaPercent: displayWindowCutoffK(for: mode))
  }

  /// Interpolate quality color ↔ display-threshold color by enter/exit weight.
  /// `weight` 0 = fully out (threshold tint, transparent); 1 = fully in (true quality color).
  static func presentationComponents(
    base: CandidateColorComponents,
    weight: Double,
    mode: QualityMode = .winrateLoss(bestWinrate: 0)
  ) -> CandidateColorComponents {
    let w = min(1.0, max(0.0, weight))
    // Smoothstep so enter/exit reads as a soft gradient, not a linear pop.
    let s = w * w * (3.0 - 2.0 * w)
    let edge = displayThresholdComponents(for: mode)
    return CandidateColorComponents(
      red: edge.red + (base.red - edge.red) * s,
      green: edge.green + (base.green - edge.green) * s,
      blue: edge.blue + (base.blue - edge.blue) * s,
      alpha: base.alpha * s
    )
  }

  static func components(deltaPercent k: Double) -> CandidateColorComponents {
    let green = (0.145, 0.647, 0.416)
    let yellow = (0.996, 0.804, 0.180)
    let orange = (0.961, 0.455, 0.098)
    let red = (0.780, 0.180, 0.302)
    let blackRed = (0.230, 0.018, 0.045)

    if k >= -3.0 {
      let t = clamp((k + 3.0) / 3.0)
      return components(green, alpha: lerp(0.56, 0.92, t))
    }
    if k >= -5.0 {
      let t = clamp((-3.0 - k) / 2.0)
      let rgb = mix(green, yellow, t)
      return components(rgb, alpha: lerp(0.56, 0.50, t))
    }
    if k >= -10.0 {
      let t = clamp((-5.0 - k) / 5.0)
      let rgb = mix(yellow, orange, t)
      return components(rgb, alpha: lerp(0.50, 0.48, t))
    }
    if k >= -20.0 {
      let t = clamp((-10.0 - k) / 10.0)
      let rgb = mix(orange, red, t)
      return components(rgb, alpha: lerp(0.48, 0.82, t))
    }
    let t = clamp((-20.0 - k) / 30.0)
    let rgb = mix(red, blackRed, t)
    return components(rgb, alpha: lerp(0.82, 0.94, t))
  }

  private static func components(
    _ rgb: (Double, Double, Double),
    alpha: Double
  ) -> CandidateColorComponents {
    CandidateColorComponents(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
  }

  private static func clamp(_ value: Double) -> Double {
    min(1.0, max(0.0, value))
  }

  private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
  }

  private static func mix(
    _ a: (Double, Double, Double),
    _ b: (Double, Double, Double),
    _ t: Double
  ) -> (Double, Double, Double) {
    (lerp(a.0, b.0, t), lerp(a.1, b.1, t), lerp(a.2, b.2, t))
  }
}
