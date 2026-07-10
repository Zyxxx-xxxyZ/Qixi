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
    nodes.append(VariationNode(id: "b6a", ply: 7, lane: 1, qualityDeltaPercent: -3.8))
    nodes.append(VariationNode(id: "b7a", ply: 8, lane: 2, qualityDeltaPercent: -8.4))
    nodes.append(VariationNode(id: "b10a", ply: 11, lane: -1, qualityDeltaPercent: -13.0))
    edges.append(VariationEdge(from: "m6", to: "b6a"))
    edges.append(VariationEdge(from: "b6a", to: "b7a"))
    edges.append(VariationEdge(from: "m10", to: "b10a"))

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
    expect(byID["b7a"]?.point.y ?? 0 > byID["b6a"]?.point.y ?? 0, "positive lanes stack downward")
    expect(byID["b10a"]?.point.y ?? 0 < byID["m10"]?.point.y ?? 0, "negative lanes stack upward")

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

    for edge in layout.edges {
      expect(edge.points.count >= 2 && edge.points.count <= 4, "edge has a simple polyline")
      for index in 1..<edge.points.count {
        let from = edge.points[index - 1]
        let to = edge.points[index]
        let dx = to.x - from.x
        let dy = to.y - from.y
        expect(dx >= -0.01, "edge segment never travels left")
        let isHorizontal = abs(dy) < 0.01
        let isVertical = abs(dx) < 0.01
        let isFortyFiveDegree = dx > 0 && abs(abs(dx) - abs(dy)) < 0.01
        expect(isHorizontal || isVertical || isFortyFiveDegree, "edge segment uses only allowed directions")
      }
    }

    print("Variation tree layout smoke passed")
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
