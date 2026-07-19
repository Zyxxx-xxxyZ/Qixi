import SwiftUI

struct VariationTreeLayout {
  static let xGap: CGFloat = 48
  static let yGap: CGFloat = 46
  static let hitTargetSide: CGFloat = 44
  static let pad: CGFloat = 26

  struct Node: Identifiable {
    var id: String
    var ply: Int
    var point: CGPoint
    var isInitial: Bool
    var isCurrent: Bool
    var qualityDeltaPercent: Double?
  }

  struct Edge {
    var path: Path
    var points: [CGPoint]
  }

  var nodes: [Node]
  var edges: [Edge]
  var size: CGSize

  init(tree: VariationTree, availableHeight: CGFloat) {
    // Lane 0 sits near vertical mid; negative lanes pack upward and must stay scrollable.
    let origin = CGPoint(x: Self.pad, y: max(Self.pad, availableHeight * 0.32))
    var positions: [String: CGPoint] = [:]
    var builtNodes: [Node] = []
    builtNodes.reserveCapacity(tree.nodes.count)

    for node in tree.nodes {
      let point = CGPoint(
        x: origin.x + CGFloat(node.ply) * Self.xGap,
        y: origin.y + CGFloat(node.lane) * Self.yGap
      )
      positions[node.id] = point
      builtNodes.append(Node(
        id: node.id,
        ply: node.ply,
        point: point,
        isInitial: node.isInitial,
        isCurrent: node.id == tree.currentNodeID,
        qualityDeltaPercent: node.qualityDeltaPercent
      ))
    }

    var builtEdges = tree.edges.compactMap { edge -> Edge? in
      guard let from = positions[edge.from], let to = positions[edge.to] else { return nil }
      let points: [CGPoint]
      if abs(from.y - to.y) < 0.5 {
        // Same lane: straight horizontal mainline / branch stem.
        points = [from, to]
      } else {
        // Vertical-first L: drop/rise to the child lane at the parent column, then
        // run horizontally. With downward-only subtree packing this never crosses —
        // the old "horizontal-first elbow" ran along the mainline and crossed siblings.
        points = [
          from,
          CGPoint(x: from.x, y: to.y),
          to
        ]
      }

      var path = Path()
      for (index, point) in points.enumerated() {
        if index == 0 {
          path.move(to: point)
        } else {
          path.addLine(to: point)
        }
      }
      return Edge(path: path, points: points)
    }

    // Shift so min X/Y sit at padding — negative lanes would otherwise clip above the scroll content.
    let minX = builtNodes.map(\.point.x).min() ?? Self.pad
    let minY = builtNodes.map(\.point.y).min() ?? Self.pad
    let shiftX = Self.pad - minX
    let shiftY = Self.pad - minY
    if abs(shiftX) > 0.01 || abs(shiftY) > 0.01 {
      for index in builtNodes.indices {
        builtNodes[index].point.x += shiftX
        builtNodes[index].point.y += shiftY
      }
      for edgeIndex in builtEdges.indices {
        var points = builtEdges[edgeIndex].points
        for p in points.indices {
          points[p].x += shiftX
          points[p].y += shiftY
        }
        var path = Path()
        for (index, point) in points.enumerated() {
          if index == 0 {
            path.move(to: point)
          } else {
            path.addLine(to: point)
          }
        }
        builtEdges[edgeIndex] = Edge(path: path, points: points)
      }
    }

    let maxX = builtNodes.map(\.point.x).max() ?? Self.pad
    let maxY = builtNodes.map(\.point.y).max() ?? Self.pad
    self.nodes = builtNodes
    self.edges = builtEdges
    self.size = CGSize(
      width: max(maxX + Self.pad + 14, 620),
      height: max(maxY + Self.pad + 16, availableHeight)
    )
  }
}
