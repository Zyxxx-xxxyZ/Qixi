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
