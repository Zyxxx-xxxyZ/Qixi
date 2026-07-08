import SwiftUI

struct VariationTreeLayout {
  static let xGap: CGFloat = 48
  static let yGap: CGFloat = 46
  static let hitTargetSide: CGFloat = 44

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
    let origin = CGPoint(x: 26, y: max(28, availableHeight * 0.32))
    var positions: [String: CGPoint] = [:]
    var builtNodes: [Node] = []

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

    let builtEdges = tree.edges.compactMap { edge -> Edge? in
      guard let from = positions[edge.from], let to = positions[edge.to] else { return nil }
      let points: [CGPoint]
      if abs(from.y - to.y) < 0.5 {
        points = [from, to]
      } else {
        let elbowX = from.x + Self.xGap * 0.56
        points = [
          from,
          CGPoint(x: elbowX, y: from.y),
          CGPoint(x: elbowX, y: to.y),
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

    let maxX = builtNodes.map(\.point.x).max() ?? 0
    let maxY = builtNodes.map(\.point.y).max() ?? 0
    self.nodes = builtNodes
    self.edges = builtEdges
    self.size = CGSize(width: max(maxX + 40, 620), height: max(maxY + 42, availableHeight))
  }
}
