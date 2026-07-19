import Foundation
import SwiftUI

@main
struct VariationTreeLayoutSmoke {
  static func main() {
    var nodes = [
      VariationNode(id: "root", ply: 0, lane: 0, qualityDeltaPercent: 0, isInitial: true)
    ]
    var edges: [VariationEdge] = []
    var previous = "root"
    for ply in 1...12 {
      let id = "m\(ply)"
      nodes.append(VariationNode(id: id, ply: ply, lane: 0, qualityDeltaPercent: Double(-ply)))
      edges.append(VariationEdge(from: previous, to: id))
      previous = id
    }
    // Non-crossing product convention: side branches only stack downward.
    // Later fork (from m6) sits closer to mainline; earlier fork (from m1) is pushed further down.
    nodes.append(VariationNode(id: "b6a", ply: 7, lane: 1, qualityDeltaPercent: -3.8))
    nodes.append(VariationNode(id: "b7a", ply: 8, lane: 1, qualityDeltaPercent: -8.4))
    nodes.append(VariationNode(id: "b10a", ply: 11, lane: 1, qualityDeltaPercent: -13.0))
    edges.append(VariationEdge(from: "m6", to: "b6a"))
    edges.append(VariationEdge(from: "b6a", to: "b7a"))
    edges.append(VariationEdge(from: "m10", to: "b10a"))

    // Branch-from-1 extended to ply 4 on a deeper lane; branch-from-3 closer to mainline.
    // Prior branch is pushed down so its edges cannot cross the later fork.
    nodes.append(VariationNode(id: "b1a", ply: 2, lane: 2, qualityDeltaPercent: -1.0))
    nodes.append(VariationNode(id: "b1b", ply: 3, lane: 2, qualityDeltaPercent: -1.2))
    nodes.append(VariationNode(id: "b1c", ply: 4, lane: 2, qualityDeltaPercent: -1.4))
    nodes.append(VariationNode(id: "b3a", ply: 4, lane: 1, qualityDeltaPercent: -2.0))
    edges.append(VariationEdge(from: "m1", to: "b1a"))
    edges.append(VariationEdge(from: "b1a", to: "b1b"))
    edges.append(VariationEdge(from: "b1b", to: "b1c"))
    edges.append(VariationEdge(from: "m3", to: "b3a"))

    let tree = VariationTree(nodes: nodes, edges: edges, currentNodeID: "m8")
    let layout = VariationTreeLayout(tree: tree, availableHeight: 220)

    expect(layout.nodes.count == nodes.count, "all nodes are laid out")
    expect(layout.edges.count == edges.count, "all edges are laid out")
    expect(layout.size.width >= 620, "layout keeps a scannable horizontal width")
    expect(layout.size.height >= 220, "layout keeps at least the viewport height")
    expect(VariationTreeLayout.xGap >= VariationTreeLayout.hitTargetSide, "horizontal gap supports finger targets")
    expect(VariationTreeLayout.yGap >= VariationTreeLayout.hitTargetSide, "vertical gap supports finger targets")

    let byID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
    expect(byID["root"]?.isInitial == true, "root node is marked as initial")
    expect(byID["m8"]?.isCurrent == true, "current ply is marked")
    expect(byID["m7"]?.isCurrent == false, "non-current ply is not marked")
    expect(byID["b6a"]?.point.y ?? 0 > byID["m6"]?.point.y ?? 0, "side branches stack downward")
    expect(byID["b10a"]?.point.y ?? 0 > byID["m10"]?.point.y ?? 0, "late side branch also stacks downward")
    // Prior branch (from m1) is pushed further down than later fork (from m3).
    expect(byID["b1c"]?.point.y ?? 0 > byID["b3a"]?.point.y ?? 0, "prior branch is pushed below later fork")

    if let first = byID["m1"], let root = byID["root"] {
      expect(abs((first.point.x - root.point.x) - VariationTreeLayout.xGap) < 0.01, "first move x gap is stable")
      expect(abs(first.point.y - root.point.y) < 0.01, "first move stays on the mainline")
    } else {
      fail("missing root or first mainline node")
    }

    for ply in 2...12 {
      guard let current = byID["m\(ply)"], let previous = byID["m\(ply - 1)"] else {
        fail("missing mainline node for ply \(ply)")
      }
      expect(abs((current.point.x - previous.point.x) - VariationTreeLayout.xGap) < 0.01, "mainline x gap is stable")
      expect(abs(current.point.y - previous.point.y) < 0.01, "mainline remains horizontal")
    }

    var minDistance = CGFloat.greatestFiniteMagnitude
    for lhsIndex in layout.nodes.indices {
      for rhsIndex in layout.nodes.indices where rhsIndex > lhsIndex {
        let lhs = layout.nodes[lhsIndex].point
        let rhs = layout.nodes[rhsIndex].point
        let distance = hypot(lhs.x - rhs.x, lhs.y - rhs.y)
        minDistance = min(minDistance, distance)
      }
    }
    expect(minDistance + 0.01 >= VariationTreeLayout.hitTargetSide, "nodes are separated by at least one hit target")

    // Explicit regression: branch-from-1 and branch-from-3 at ply 4 must not coincide.
    if let b1c = byID["b1c"], let b3a = byID["b3a"], let m4 = byID["m4"] {
      expect(b1c.point.x == m4.point.x && b3a.point.x == m4.point.x, "ply-4 nodes share the same column")
      expect(abs(b1c.point.y - b3a.point.y) + 0.01 >= VariationTreeLayout.yGap,
             "branch-from-1 and branch-from-3 do not overlap at ply 4")
      expect(abs(b1c.point.y - m4.point.y) + 0.01 >= VariationTreeLayout.yGap,
             "branch-from-1 does not overlap mainline at ply 4")
      expect(abs(b3a.point.y - m4.point.y) + 0.01 >= VariationTreeLayout.yGap,
             "branch-from-3 does not overlap mainline at ply 4")
    } else {
      fail("missing ply-4 branch nodes for overlap regression")
    }

    // Orthogonal edge segments must not properly cross (shared endpoints allowed).
    expect(!orthogonalEdgesCross(layout.edges), "variation edges must not cross")

    for edge in layout.edges {
      expect(edge.points.count >= 2 && edge.points.count <= 3, "edge is straight or vertical-first L")
      for index in 1..<edge.points.count {
        let from = edge.points[index - 1]
        let to = edge.points[index]
        let dx = to.x - from.x
        let dy = to.y - from.y
        expect(dx >= -0.01, "edge segment never travels left")
        let isHorizontal = abs(dy) < 0.01
        let isVertical = abs(dx) < 0.01
        expect(isHorizontal || isVertical, "edge segment is axis-aligned only")
      }
    }

    
    // Side-to-move: empty history uses rootToMove (SGF/setup may start with White).
    expect(
      QixiBoardPosition.nextPlayer(after: [], rootToMove: .white) == .white,
      "empty history preserves White-to-play root"
    )
    expect(
      QixiBoardPosition.nextPlayer(after: [BoardMove(color: .white, x: 3, y: 3)], rootToMove: .white) == .black,
      "after White first move, Black is to play"
    )
    expect(
      QixiBoardPosition.nextPlayer(after: [BoardMove(color: .white, x: 3, y: 3), BoardMove(color: .black, x: 15, y: 3)], rootToMove: .white) == .white,
      "White-first line alternates correctly"
    )
    // Black-side chart polarity: White-to-play root must flip STM values.
    // (Mirrors QixiViewModel.blackSideChartValues logic.)
    func blackSide(winrate: Double, scoreMean: Double, atPly ply: Int, mainLine: [BoardMove]) -> (Double, Double) {
      let moves = Array(mainLine.prefix(max(0, ply)))
      let rootToMove = mainLine.first?.color ?? .black
      let stm = QixiBoardPosition.nextPlayer(after: moves, rootToMove: rootToMove)
      if stm == .black { return (winrate, scoreMean) }
      return (1.0 - winrate, -scoreMean)
    }
    let whiteFirst = [BoardMove(color: .white, x: 3, y: 3), BoardMove(color: .black, x: 15, y: 3)]
    let (wr0, sc0) = blackSide(winrate: 0.40, scoreMean: -2.0, atPly: 0, mainLine: whiteFirst)
    expect(abs(wr0 - 0.60) < 1e-9 && abs(sc0 - 2.0) < 1e-9, "White-to-play root flips STM winrate/score to Black side")
    let (wr1, sc1) = blackSide(winrate: 0.55, scoreMean: 1.0, atPly: 1, mainLine: whiteFirst)
    expect(abs(wr1 - 0.55) < 1e-9 && abs(sc1 - 1.0) < 1e-9, "Black-to-play after White first does not flip")
    let blackFirst = [BoardMove(color: .black, x: 3, y: 3), BoardMove(color: .white, x: 15, y: 3)]
    let (wrOdd, _) = blackSide(winrate: 0.40, scoreMean: -2.0, atPly: 1, mainLine: blackFirst)
    expect(abs(wrOdd - 0.60) < 1e-9, "standard odd ply (White to play) still flips")


    print("Variation tree layout smoke passed")
  }

  /// True if any two axis-aligned segments properly cross (shared endpoints / T-junctions OK).
  static func orthogonalEdgesCross(_ edges: [VariationTreeLayout.Edge]) -> Bool {
    func segments(of edge: VariationTreeLayout.Edge) -> [(CGPoint, CGPoint)] {
      zip(edge.points, edge.points.dropFirst()).map { ($0, $1) }
    }
    func nearlyEqual(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
    func properCross(_ p1: CGPoint, _ q1: CGPoint, _ p2: CGPoint, _ q2: CGPoint) -> Bool {
      let h1 = nearlyEqual(p1.y, q1.y)
      let v1 = nearlyEqual(p1.x, q1.x)
      let h2 = nearlyEqual(p2.y, q2.y)
      let v2 = nearlyEqual(p2.x, q2.x)
      // Only a horizontal × vertical pair can properly cross.
      guard (h1 && v2) || (v1 && h2) else { return false }
      let (hA, hB, vA, vB) = h1
        ? (p1, q1, p2, q2)
        : (p2, q2, p1, q1)
      let y = hA.y
      let x = vA.x
      let minHX = min(hA.x, hB.x), maxHX = max(hA.x, hB.x)
      let minVY = min(vA.y, vB.y), maxVY = max(vA.y, vB.y)
      // Strict interior intersection (not endpoint T-junction).
      return x > minHX + 0.01 && x < maxHX - 0.01 &&
        y > minVY + 0.01 && y < maxVY - 0.01
    }
    let allSegs = edges.flatMap(segments(of:))
    for i in allSegs.indices {
      for j in allSegs.indices where j > i {
        if properCross(allSegs[i].0, allSegs[i].1, allSegs[j].0, allSegs[j].1) {
          return true
        }
      }
    }
    return false
  }

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fail(message)
    }
  }

  static func fail(_ message: String) -> Never {
    fputs("Variation tree layout smoke failed: \(message)\n", stderr)
    exit(1)
  }
}
