import Foundation

@main
struct VariationIncrementalSmoke {
  static func main() {
    do {
      try run()
      print("Variation incremental smoke passed")
    } catch {
      fail(String(describing: error))
    }
  }

  enum SmokeError: Error {
    case failed(String)
  }

  static func run() throws {
    // Root + one child (lineages 1 and 2).
    let base = try decodeSnapshot("""
    {
      "root": 0,
      "rootLineageHash": 1,
      "rootVisits": 10,
      "rootWinrate": 0.5,
      "rootScoreMean": 0.0,
      "hasOwnership": false,
      "candidates": [],
      "visibleTree": [
        {
          "id": 0,
          "lineageHash": 1,
          "moveFromParent": 0,
          "moveColor": "black",
          "ply": 0,
          "visits": 10,
          "winrate": 0.5,
          "scoreMean": 0.0,
          "analyzed": true,
          "qualityDeltaPercent": null
        },
        {
          "id": 1,
          "lineageHash": 2,
          "parent": 0,
          "moveFromParent": 60,
          "moveColor": "black",
          "ply": 1,
          "visits": 5,
          "winrate": 0.55,
          "scoreMean": 1.0,
          "analyzed": true,
          "qualityDeltaPercent": -1.5
        }
      ],
      "ownership": []
    }
    """)

    var model = QixiVariationModel()
    let boardMove: (Int, String) -> BoardMove? = { move, colorText in
      let color: StoneColor = colorText == "white" ? .white : .black
      if move < 0 || move >= 19 * 19 {
        return BoardMove(pass: color)
      }
      return BoardMove(color: color, x: move % 19, y: move / 19)
    }

    let first = model.apply(from: base, boardMove: boardMove)
    expect(first == .structureChanged, "first apply is structural")
    expect(model.projectionUsesCoreIDs, "core ids after first apply")
    expect(model.records.count == 2, "two nodes after first apply")
    let idRoot = QixiVariationModel.coreVariationNodeID(1)
    let idChild = QixiVariationModel.coreVariationNodeID(2)
    expect(model.records[idRoot] != nil, "root present")
    expect(model.records[idChild] != nil, "child present")
    let laneChild = model.records[idChild]?.lane
    let fingerprint = model.lastTopologyFingerprint
    expect(fingerprint != 0, "fingerprint recorded")

    // Same topology, different quality/visits → metrics only.
    let metrics = try decodeSnapshot("""
    {
      "root": 0,
      "rootLineageHash": 1,
      "rootVisits": 40,
      "rootWinrate": 0.51,
      "rootScoreMean": 0.2,
      "hasOwnership": false,
      "candidates": [],
      "visibleTree": [
        {
          "id": 0,
          "lineageHash": 1,
          "moveFromParent": 0,
          "moveColor": "black",
          "ply": 0,
          "visits": 40,
          "winrate": 0.51,
          "scoreMean": 0.2,
          "analyzed": true,
          "qualityDeltaPercent": null
        },
        {
          "id": 1,
          "lineageHash": 2,
          "parent": 0,
          "moveFromParent": 60,
          "moveColor": "black",
          "ply": 1,
          "visits": 20,
          "winrate": 0.56,
          "scoreMean": 1.2,
          "analyzed": true,
          "qualityDeltaPercent": -2.25
        }
      ],
      "ownership": []
    }
    """)
    let second = model.apply(from: metrics, boardMove: boardMove)
    expect(second == .metricsOnly, "second apply is metrics-only")
    expect(model.lastTopologyFingerprint == fingerprint, "fingerprint stable on metrics-only")
    expect(model.records[idChild]?.lane == laneChild, "lane unchanged on metrics-only")
    expect(model.coreQualityDeltaByNodeID[idChild] == -2.25, "quality patched")

    // Add a sibling branch (structure).
    let expanded = try decodeSnapshot("""
    {
      "root": 0,
      "rootLineageHash": 1,
      "rootVisits": 50,
      "rootWinrate": 0.52,
      "rootScoreMean": 0.3,
      "hasOwnership": false,
      "candidates": [],
      "visibleTree": [
        {
          "id": 0,
          "lineageHash": 1,
          "moveFromParent": 0,
          "moveColor": "black",
          "ply": 0,
          "visits": 50,
          "winrate": 0.52,
          "scoreMean": 0.3,
          "analyzed": true
        },
        {
          "id": 1,
          "lineageHash": 2,
          "parent": 0,
          "moveFromParent": 60,
          "moveColor": "black",
          "ply": 1,
          "visits": 20,
          "winrate": 0.56,
          "scoreMean": 1.2,
          "analyzed": true,
          "qualityDeltaPercent": -2.0
        },
        {
          "id": 2,
          "lineageHash": 3,
          "parent": 0,
          "moveFromParent": 72,
          "moveColor": "black",
          "ply": 1,
          "visits": 8,
          "winrate": 0.48,
          "scoreMean": -0.5,
          "analyzed": true,
          "qualityDeltaPercent": 1.0
        }
      ],
      "ownership": []
    }
    """)
    let third = model.apply(from: expanded, boardMove: boardMove)
    expect(third == .structureChanged, "add branch is structural")
    let idSib = QixiVariationModel.coreVariationNodeID(3)
    expect(model.records[idSib] != nil, "sibling present")
    expect(model.records.count == 3, "three nodes after expand")

    // Remove sibling (structure).
    let shrunk = try decodeSnapshot("""
    {
      "root": 0,
      "rootLineageHash": 1,
      "rootVisits": 55,
      "rootWinrate": 0.53,
      "rootScoreMean": 0.4,
      "hasOwnership": false,
      "candidates": [],
      "visibleTree": [
        {
          "id": 0,
          "lineageHash": 1,
          "moveFromParent": 0,
          "moveColor": "black",
          "ply": 0,
          "visits": 55,
          "winrate": 0.53,
          "scoreMean": 0.4,
          "analyzed": true
        },
        {
          "id": 1,
          "lineageHash": 2,
          "parent": 0,
          "moveFromParent": 60,
          "moveColor": "black",
          "ply": 1,
          "visits": 30,
          "winrate": 0.57,
          "scoreMean": 1.3,
          "analyzed": true
        }
      ],
      "ownership": []
    }
    """)
    let fourth = model.apply(from: shrunk, boardMove: boardMove)
    expect(fourth == .structureChanged, "remove branch is structural")
    expect(model.records[idSib] == nil, "sibling removed")
    expect(model.records.count == 2, "two nodes after shrink")

    // Empty tree → no-op
    let empty = try decodeSnapshot("""
    {
      "root": 0,
      "rootLineageHash": 1,
      "rootVisits": 0,
      "rootWinrate": 0.5,
      "rootScoreMean": 0.0,
      "hasOwnership": false,
      "candidates": [],
      "visibleTree": [],
      "ownership": []
    }
    """)
    let fifth = model.apply(from: empty, boardMove: boardMove)
    expect(fifth == .noOp, "empty visible tree is no-op")
    expect(model.records.count == 2, "tree preserved on empty snapshot")

    // Local reset then apply → structural (id scheme switch).
    model.reset(from: [BoardMove(color: .black, x: 3, y: 3)], currentPly: 1)
    expect(!model.projectionUsesCoreIDs, "local reset clears core projection flag")
    let afterLocal = model.apply(from: base, boardMove: boardMove)
    expect(afterLocal == .structureChanged, "local→core is structural")
    expect(model.projectionUsesCoreIDs, "core ids after local→core")
    expect(model.records[idChild] != nil, "child present after local→core")

    // Regression: branch from ply 1 and branch from ply 3 must not share a lane at ply 4.
    var branchModel = QixiVariationModel()
    let main = [
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 3),
      BoardMove(color: .black, x: 3, y: 15),
      BoardMove(color: .white, x: 15, y: 15)
    ]
    var line = main
    var ply = 4
    branchModel.reset(from: main, currentPly: 4)
    let path = branchModel.currentPathNodeIDs
    expect(path.count == 5, "mainline has root + 4 moves")

    // Fork at step 1 (after first move): extend a side branch to ply 4.
    branchModel.syncCurrentLine(
      to: path[1],
      includePrimaryContinuation: false,
      mainLine: &line,
      currentPly: &ply
    )
    _ = branchModel.appendMove(BoardMove(color: .white, x: 4, y: 3), atPly: 2)
    branchModel.syncCurrentLine(
      to: branchModel.currentNodeID,
      includePrimaryContinuation: false,
      mainLine: &line,
      currentPly: &ply
    )
    // After appendMove, currentNodeID is still the parent unless caller advances.
    // Walk to the newly appended leaf via children.
    let fork1Parent = path[1]
    let fork1Child = branchModel.childIDsByParent[fork1Parent]?.last
    expect(fork1Child != nil, "fork from step 1 created")
    if let fork1Child {
      branchModel.syncCurrentLine(
        to: fork1Child,
        includePrimaryContinuation: false,
        mainLine: &line,
        currentPly: &ply
      )
      let b3 = branchModel.appendMove(BoardMove(color: .black, x: 4, y: 4), atPly: 3)
      branchModel.syncCurrentLine(
        to: b3,
        includePrimaryContinuation: false,
        mainLine: &line,
        currentPly: &ply
      )
      _ = branchModel.appendMove(BoardMove(color: .white, x: 4, y: 5), atPly: 4)
    }

    // Fork at step 3: one-step branch into ply 4.
    branchModel.syncCurrentLine(
      to: path[3],
      includePrimaryContinuation: false,
      mainLine: &line,
      currentPly: &ply
    )
    _ = branchModel.appendMove(BoardMove(color: .white, x: 16, y: 15), atPly: 4)

    var keys = Set<String>()
    for record in branchModel.records.values {
      let key = "\(record.ply):\(record.lane)"
      expect(!keys.contains(key), "no two nodes share ply/lane (\(key))")
      keys.insert(key)
    }
    let ply4 = branchModel.records.values.filter { $0.ply == 4 }
    expect(ply4.count >= 3, "main + two branches present at ply 4")
    let ply4Lanes = Set(ply4.map(\.lane))
    expect(ply4Lanes.count == ply4.count, "distinct lanes at ply 4 (branch-from-1 vs branch-from-3)")
    // Mainline node at ply 4 is path[4].
    expect(branchModel.records[path[4]]?.lane == 0, "mainline stays on lane 0")
    // All side-branch lanes must be strictly positive (down only).
    for record in branchModel.records.values where record.lane != 0 {
      expect(record.lane > 0, "side branches only stack downward (lane \(record.lane))")
    }
    // Prior branch-from-1 leaf is deeper than later branch-from-3.
    let fork3Lane = branchModel.records.values.first {
      $0.ply == 4 && $0.parentID == path[3] && $0.id != path[4]
    }?.lane
    let fork1LeafLane = branchModel.records.values
      .filter { $0.ply == 4 && $0.id != path[4] && $0.parentID != path[3] }
      .map(\.lane)
      .max()
    if let fork3Lane, let fork1LeafLane {
      expect(
        fork1LeafLane > fork3Lane,
        "prior branch is pushed below later fork (prior=\(fork1LeafLane) later=\(fork3Lane))"
      )
    }

    // Spine preservation: after structure refresh, keep the user's forward path
    // instead of jumping to first-child-by-core-id.
    var spineModel = QixiVariationModel()
    spineModel.reset(
      from: [
        BoardMove(color: .black, x: 3, y: 3),
        BoardMove(color: .white, x: 15, y: 3)
      ],
      currentPly: 1
    )
    let prevPath = spineModel.currentPathNodeIDs
    expect(prevPath.count == 3, "local path is root + 2 moves")
    // Simulate a core projection with two children of root: prefer lower id first
    // (would steal the mainline if we only used first-child primary).
    let forked = try decodeSnapshot("""
    {
      "root": 1,
      "rootLineageHash": 10,
      "rootVisits": 4,
      "rootWinrate": 0.5,
      "rootScoreMean": 0.0,
      "hasOwnership": false,
      "candidates": [],
      "visibleTree": [
        {"id": 0, "lineageHash": 1, "moveFromParent": 0, "moveColor": "black", "ply": 0, "visits": 4, "winrate": 0.5, "scoreMean": 0.0, "analyzed": true},
        {"id": 2, "lineageHash": 20, "parent": 0, "moveFromParent": 60, "moveColor": "black", "ply": 1, "visits": 1, "winrate": 0.4, "scoreMean": 0.0, "analyzed": true},
        {"id": 1, "lineageHash": 10, "parent": 0, "moveFromParent": 48, "moveColor": "black", "ply": 1, "visits": 3, "winrate": 0.55, "scoreMean": 0.0, "analyzed": true},
        {"id": 3, "lineageHash": 30, "parent": 1, "moveFromParent": 288, "moveColor": "white", "ply": 2, "visits": 2, "winrate": 0.5, "scoreMean": 0.0, "analyzed": true}
      ],
      "ownership": []
    }
    """)
    _ = spineModel.apply(from: forked, boardMove: boardMove)
    // After apply current is lineage 10 (id 1). Previous local path no longer matches
    // core ids — spine falls back to primary from current.
    let afterCore = spineModel.spinePreservingPreviousPath(
      previousPath: ["l1", "l10", "l30"],
      currentID: "l10"
    )
    expect(afterCore.contains("l10"), "preserved spine includes current")
    expect(afterCore.contains("l30"), "preserved spine keeps forward child on prior path")
    expect(!afterCore.contains("l20") || afterCore.firstIndex(of: "l10")! > 0,
           "side branch l20 is not forced as the only continuation")
  }

  static func decodeSnapshot(_ json: String) throws -> QixiCoreSnapshot {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(QixiCoreSnapshot.self, from: data)
  }

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fail(message)
    }
  }

  static func fail(_ message: String) -> Never {
    fputs("Variation incremental smoke failed: \(message)\n", stderr)
    exit(1)
  }
}
