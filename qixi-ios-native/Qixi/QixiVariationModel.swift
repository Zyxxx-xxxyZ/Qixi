import Foundation

/// Owns the main-page variation tree projection (not the core MCTS store).
/// ViewModel remains the ObservableObject façade; this type holds tree structure state.
@MainActor
struct QixiVariationModel {
  static let rootID = "root"

  struct NodeRecord: Equatable {
    var id: String
    var parentID: String?
    var move: BoardMove?
    var ply: Int
    var lane: Int
    var isInitial: Bool
  }

  var records: [String: NodeRecord] = [:]
  var childIDsByParent: [String: [String]] = [:]
  var currentNodeID = QixiVariationModel.rootID
  var currentPathNodeIDs = [QixiVariationModel.rootID]
  var nextSequence = 1
  var coreQualityDeltaByNodeID: [String: Double] = [:]
  var coreRootReferenceByNodeID: [String: QixiCoreRootReference] = [
    QixiVariationModel.rootID: .node(0)
  ]

  mutating func reset(from moves: [BoardMove], currentPly: Int) {
    coreQualityDeltaByNodeID = [:]
    records = [
      Self.rootID: NodeRecord(
        id: Self.rootID,
        parentID: nil,
        move: nil,
        ply: 0,
        lane: 0,
        isInitial: true
      )
    ]
    childIDsByParent = [Self.rootID: []]
    currentNodeID = Self.rootID
    currentPathNodeIDs = [Self.rootID]
    nextSequence = 1
    coreRootReferenceByNodeID = [Self.rootID: .node(0)]

    var parentID = Self.rootID
    var nodeAtCurrentPly = Self.rootID
    var fullPath = [Self.rootID]
    for (index, move) in moves.enumerated() {
      let nodeID = makeNodeID()
      let ply = index + 1
      let record = NodeRecord(
        id: nodeID,
        parentID: parentID,
        move: move,
        ply: ply,
        lane: 0,
        isInitial: false
      )
      records[nodeID] = record
      childIDsByParent[parentID, default: []].append(nodeID)
      childIDsByParent[nodeID] = []
      parentID = nodeID
      fullPath.append(nodeID)
      if ply <= currentPly {
        nodeAtCurrentPly = nodeID
      }
    }
    currentPathNodeIDs = fullPath
    currentNodeID = nodeAtCurrentPly
  }

  mutating func makeNodeID() -> String {
    defer { nextSequence += 1 }
    return "v\(nextSequence)"
  }

  func pathNodeIDs(to nodeID: String) -> [String] {
    var path: [String] = []
    var cursor: String? = records[nodeID] == nil ? Self.rootID : nodeID
    var visited = Set<String>()
    while let id = cursor, visited.insert(id).inserted, let record = records[id] {
      path.append(id)
      cursor = record.parentID
    }
    return path.reversed()
  }

  func moves(to nodeID: String) -> [BoardMove] {
    pathNodeIDs(to: nodeID).compactMap { records[$0]?.move }
  }

  func primaryPathNodeIDs(from nodeID: String) -> [String] {
    let boundedNodeID = records[nodeID] == nil ? Self.rootID : nodeID
    var path = pathNodeIDs(to: boundedNodeID)
    var cursor = boundedNodeID
    var visited = Set(path)
    while let childID = childIDsByParent[cursor]?.first(where: { !visited.contains($0) }) {
      path.append(childID)
      visited.insert(childID)
      cursor = childID
    }
    return path
  }

  func nodeID(onCurrentPathAt ply: Int, mainLineCount: Int) -> String {
    let boundedPly = min(max(0, ply), mainLineCount)
    guard boundedPly < currentPathNodeIDs.count else {
      return currentPathNodeIDs.last ?? Self.rootID
    }
    return currentPathNodeIDs[boundedPly]
  }

  mutating func syncCurrentLine(
    to nodeID: String,
    includePrimaryContinuation: Bool,
    mainLine: inout [BoardMove],
    currentPly: inout Int
  ) {
    let boundedNodeID = records[nodeID] == nil ? Self.rootID : nodeID
    currentPathNodeIDs = includePrimaryContinuation
      ? primaryPathNodeIDs(from: boundedNodeID)
      : pathNodeIDs(to: boundedNodeID)
    currentNodeID = boundedNodeID
    mainLine = currentPathNodeIDs.compactMap { records[$0]?.move }
    currentPly = min(records[boundedNodeID]?.ply ?? 0, mainLine.count)
  }

  mutating func appendMove(_ move: BoardMove, atPly ply: Int) -> String {
    let parentID = currentNodeID
    let nodeID = makeNodeID()
    let siblings = childIDsByParent[parentID] ?? []
    let lane: Int
    if siblings.isEmpty {
      lane = records[parentID]?.lane ?? 0
    } else {
      let parentLane = records[parentID]?.lane ?? 0
      let siblingIndex = siblings.count
      lane = parentLane + (siblingIndex.isMultiple(of: 2) ? -siblingIndex : siblingIndex)
    }
    records[nodeID] = NodeRecord(
      id: nodeID,
      parentID: parentID,
      move: move,
      ply: ply,
      lane: lane,
      isInitial: false
    )
    childIDsByParent[parentID, default: []].append(nodeID)
    childIDsByParent[nodeID] = []
    return nodeID
  }

  func nextAvailableLane(preferredSign: Int) -> Int {
    let used = Set(records.values.map(\.lane))
    var lane = preferredSign >= 0 ? 1 : -1
    var step = 1
    while used.contains(lane) {
      step += 1
      lane = (step % 2 == 0 ? -1 : 1) * ((step + 1) / 2)
    }
    return lane
  }

  func variationTree(
    qualityDelta: (NodeRecord) -> Double?
  ) -> VariationTree {
    let orderedRecords = records.values.sorted {
      if $0.ply != $1.ply { return $0.ply < $1.ply }
      return $0.id < $1.id
    }
    let nodes = orderedRecords.map { record in
      VariationNode(
        id: record.id,
        ply: record.ply,
        lane: record.lane,
        qualityDeltaPercent: qualityDelta(record),
        isInitial: record.isInitial
      )
    }
    let edges = orderedRecords.compactMap { record -> VariationEdge? in
      guard let parentID = record.parentID else { return nil }
      return VariationEdge(from: parentID, to: record.id)
    }
    return VariationTree(nodes: nodes, edges: edges, currentNodeID: currentNodeID)
  }

  /// Rebuild from a bounded core light snapshot.
  mutating func rebuild(
    from snapshot: QixiCoreSnapshot,
    boardMove: (Int, String) -> BoardMove?,
    maxLayoutNodes: Int = 4096
  ) {
    guard !snapshot.visibleTree.isEmpty else { return }
    var nextRecords: [String: NodeRecord] = [:]
    var nextChildren: [String: [String]] = [:]
    var laneByNode: [UInt32: Int] = [:]
    let orderedNodes = snapshot.visibleTree
      .prefix(maxLayoutNodes)
      .sorted {
        if $0.ply != $1.ply { return $0.ply < $1.ply }
        return $0.id < $1.id
      }
    let variationIDByCoreNodeID = Dictionary(
      uniqueKeysWithValues: orderedNodes.map { ($0.id, Self.coreVariationNodeID($0.lineageHash)) }
    )
    for node in orderedNodes {
      let nodeID = Self.coreVariationNodeID(node.lineageHash)
      let parentID = node.parent.flatMap { variationIDByCoreNodeID[$0] }
      let siblingIndex = parentID.flatMap { nextChildren[$0]?.count } ?? 0
      let parentLane = node.parent.flatMap { laneByNode[$0] } ?? 0
      let lane = node.parent == nil
        ? 0
        : (siblingIndex == 0 ? parentLane : parentLane + (siblingIndex.isMultiple(of: 2) ? -siblingIndex : siblingIndex))
      let move = boardMove(node.moveFromParent, node.moveColor)
      nextRecords[nodeID] = NodeRecord(
        id: nodeID,
        parentID: parentID,
        move: move,
        ply: Int(node.ply),
        lane: lane,
        isInitial: node.parent == nil
      )
      if nextChildren[nodeID] == nil {
        nextChildren[nodeID] = []
      }
      if let parentID {
        nextChildren[parentID, default: []].append(nodeID)
      }
      laneByNode[node.id] = lane
    }
    let currentID = Self.coreVariationNodeID(snapshot.rootLineageHash)
    guard nextRecords[currentID] != nil else { return }
    records = nextRecords
    childIDsByParent = nextChildren
    coreRootReferenceByNodeID = Dictionary(
      uniqueKeysWithValues: orderedNodes.map {
        (Self.coreVariationNodeID($0.lineageHash), .lineage($0.lineageHash))
      }
    )
    coreQualityDeltaByNodeID = Dictionary(
      uniqueKeysWithValues: orderedNodes.compactMap { node in
        node.qualityDeltaPercent.map { (Self.coreVariationNodeID(node.lineageHash), $0) }
      }
    )
    currentNodeID = currentID
    currentPathNodeIDs = pathNodeIDs(to: currentNodeID)
    nextSequence = max(nextSequence, records.count + 1)
  }

  static func coreVariationNodeID(_ lineageHash: UInt64) -> String {
    "l\(lineageHash)"
  }
}
