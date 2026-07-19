import Foundation

/// Builds ranked + dyed candidate presentation from winrate/score using `CandidatePalette` policy.
enum CandidateQualityLayout {
  struct Item {
    var x: Int
    var y: Int
    var visits: Int
    var winrate: Double
    var scoreMean: Double
    /// Original engine order index (visit order) as stable tie-break.
    var sourceIndex: Int
  }

  struct Ranked {
    var x: Int
    var y: Int
    var visits: Int
    var winrate: Double
    var scoreMean: Double
    var rank: Int
    /// Palette k (≤0 worse). Winrate-loss or −score-loss.
    var paletteDeltaK: Double
    var colorComponents: CandidateColorComponents
    var mode: CandidatePalette.QualityMode
  }

  /// Rank, dye, and optionally window-filter candidates.
  /// - `positionSideToMoveWinrate`: root STM winrate (core). Ensures extreme-low score-loss
  ///   when the **side to move** is ≤ 5% even if peer list outliers look healthy.
  static func layout(
    _ items: [Item],
    positionSideToMoveWinrate: Double? = nil
  ) -> (mode: CandidatePalette.QualityMode?, ranked: [Ranked]) {
    let active = items.filter { $0.visits > 0 }
    guard !active.isEmpty else { return (nil, []) }

    let rawWinrates = active.map(\.winrate)
    let rawScores = active.map(\.scoreMean)
    let normalized = CandidatePalette.normalizedSideToMovePeers(
      winrates: rawWinrates,
      scores: rawScores,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    )
    guard let mode = CandidatePalette.qualityMode(
      winrates: normalized.winrates,
      scores: normalized.scores,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    ) else {
      return (nil, [])
    }

    // Pair normalized STM metrics with each active item for ranking / k.
    struct STMItem {
      var item: Item
      var winrate: Double
      var scoreMean: Double
    }
    let stmItems: [STMItem] = zip(active, zip(normalized.winrates, normalized.scores)).map {
      STMItem(item: $0.0, winrate: $0.1.0, scoreMean: $0.1.1)
    }

    let sorted: [STMItem]
    switch mode {
    case .winrateLoss:
      // Keep engine visit order (sourceIndex), which is how core ranked top-K.
      sorted = stmItems.sorted { a, b in
        if a.item.sourceIndex != b.item.sourceIndex {
          return a.item.sourceIndex < b.item.sourceIndex
        }
        return a.item.visits > b.item.visits
      }
    case .scoreLoss:
      sorted = stmItems.sorted { a, b in
        if a.scoreMean != b.scoreMean { return a.scoreMean > b.scoreMean }
        if a.item.visits != b.item.visits { return a.item.visits > b.item.visits }
        return a.item.sourceIndex < b.item.sourceIndex
      }
    }

    var ranked: [Ranked] = []
    ranked.reserveCapacity(sorted.count)
    var displayRank = 0
    for stm in sorted {
      let k = CandidatePalette.paletteDeltaK(
        winrate: stm.winrate,
        scoreMean: stm.scoreMean,
        mode: mode
      )
      guard CandidatePalette.isInDisplayWindow(paletteDeltaK: k, mode: mode) else { continue }
      displayRank += 1
      ranked.append(
        Ranked(
          x: stm.item.x,
          y: stm.item.y,
          visits: stm.item.visits,
          // Keep published (raw) metrics for labels; color uses STM k.
          winrate: stm.item.winrate,
          scoreMean: stm.item.scoreMean,
          rank: displayRank,
          paletteDeltaK: k,
          colorComponents: CandidatePalette.components(deltaPercent: k),
          mode: mode
        )
      )
    }
    return (mode, ranked)
  }
}
