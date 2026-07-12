import Foundation

/// Result of applying a core light snapshot to the UI variation projection.
enum VariationApplyResult: Equatable {
  case noOp
  case metricsOnly
  case structureChanged
}

/// Owns the main-page variation tree projection (not the core MCTS store).
/// ViewModel remains the ObservableObject façade; this type holds tree structure state.
/// Not marked `@MainActor` so pure smokes can exercise apply/diff without a run loop;
/// product mutations still run only from the main-actor ViewModel.
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
  /// Topology fingerprint of the last successful core apply (metrics-only fast path).
  private(set) var lastTopologyFingerprint: UInt64 = 0
  /// True once the projection is keyed by core lineage ids (`l…`).
  private(set) var projectionUsesCoreIDs = false

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
    lastTopologyFingerprint = 0
    projectionUsesCoreIDs = false

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
    // Local optimistic ids invalidate core topology fingerprint.
    lastTopologyFingerprint = 0
    projectionUsesCoreIDs = false
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

  /// Incremental apply from a bounded core light snapshot (metrics-only or set-diff).
  @discardableResult
  mutating func apply(
    from snapshot: QixiCoreSnapshot,
    boardMove: (Int, String) -> BoardMove?,
    maxLayoutNodes: Int = 4096
  ) -> VariationApplyResult {
    guard !snapshot.visibleTree.isEmpty else { return .noOp }

    let prepared = Self.prepareOrderedNodes(
      from: snapshot,
      maxLayoutNodes: maxLayoutNodes
    )
    let currentID = Self.coreVariationNodeID(snapshot.rootLineageHash)
    guard prepared.variationIDByCoreNodeID.values.contains(currentID) ||
            prepared.nodes.contains(where: { Self.coreVariationNodeID($0.lineageHash) == currentID })
    else {
      // Missing current root in capped tree — preserve prior projection.
      return .noOp
    }

    // Local / optimistic trees must full-rebuild into lineage ids.
    if !projectionUsesCoreIDs || hasNonCoreRecordIDs {
      fullRebuild(from: prepared, snapshot: snapshot, boardMove: boardMove, currentID: currentID)
      return .structureChanged
    }

    let fingerprint = Self.topologyFingerprint(
      rootLineage: snapshot.rootLineageHash,
      nodes: prepared.fingerprintNodes
    )

    if fingerprint == lastTopologyFingerprint,
       records[currentID] != nil {
      return applyMetricsOnly(
        prepared: prepared,
        snapshot: snapshot,
        currentID: currentID
      )
    }

    if applySetDiff(
      prepared: prepared,
      snapshot: snapshot,
      boardMove: boardMove,
      currentID: currentID,
      fingerprint: fingerprint
    ) {
      return .structureChanged
    }

    fullRebuild(from: prepared, snapshot: snapshot, boardMove: boardMove, currentID: currentID)
    return .structureChanged
  }

  /// Full replace from a core light snapshot (boot / fallback / tests).
  mutating func rebuild(
    from snapshot: QixiCoreSnapshot,
    boardMove: (Int, String) -> BoardMove?,
    maxLayoutNodes: Int = 4096
  ) {
    guard !snapshot.visibleTree.isEmpty else { return }
    let prepared = Self.prepareOrderedNodes(from: snapshot, maxLayoutNodes: maxLayoutNodes)
    let currentID = Self.coreVariationNodeID(snapshot.rootLineageHash)
    guard prepared.nodes.contains(where: { Self.coreVariationNodeID($0.lineageHash) == currentID }) else {
      return
    }
    fullRebuild(from: prepared, snapshot: snapshot, boardMove: boardMove, currentID: currentID)
  }

  static func coreVariationNodeID(_ lineageHash: UInt64) -> String {
    "l\(lineageHash)"
  }

  // MARK: - Incremental internals

  private var hasNonCoreRecordIDs: Bool {
    records.keys.contains { id in
      id != Self.rootID && !id.hasPrefix("l")
    }
  }

  private struct PreparedSnapshot {
    var nodes: [QixiCoreTreeNode]
    var variationIDByCoreNodeID: [UInt32: String]
    var parentVariationIDByCoreNodeID: [UInt32: String?]
    var fingerprintNodes: [(lineage: UInt64, parentLineage: UInt64?, ply: UInt32, move: Int)]
  }

  private static func prepareOrderedNodes(
    from snapshot: QixiCoreSnapshot,
    maxLayoutNodes: Int
  ) -> PreparedSnapshot {
    let orderedNodes = Array(
      snapshot.visibleTree
        .prefix(maxLayoutNodes)
        .sorted {
          if $0.ply != $1.ply { return $0.ply < $1.ply }
          return $0.id < $1.id
        }
    )
    let variationIDByCoreNodeID = Dictionary(
      uniqueKeysWithValues: orderedNodes.map { ($0.id, coreVariationNodeID($0.lineageHash)) }
    )
    let lineageByCoreID = Dictionary(
      uniqueKeysWithValues: orderedNodes.map { ($0.id, $0.lineageHash) }
    )
    var parentVariationIDByCoreNodeID: [UInt32: String?] = [:]
    var fingerprintNodes: [(lineage: UInt64, parentLineage: UInt64?, ply: UInt32, move: Int)] = []
    fingerprintNodes.reserveCapacity(orderedNodes.count)
    for node in orderedNodes {
      let parentLineage: UInt64?
      let parentVar: String?
      if let parent = node.parent, let parentLin = lineageByCoreID[parent] {
        parentLineage = parentLin
        parentVar = coreVariationNodeID(parentLin)
      } else if node.parent == nil {
        parentLineage = nil
        parentVar = nil
      } else {
        // Parent trimmed out of light snapshot — still record nil parent for fingerprint stability.
        parentLineage = nil
        parentVar = nil
      }
      parentVariationIDByCoreNodeID[node.id] = parentVar
      fingerprintNodes.append(
        (lineage: node.lineageHash, parentLineage: parentLineage, ply: node.ply, move: node.moveFromParent)
      )
    }
    return PreparedSnapshot(
      nodes: orderedNodes,
      variationIDByCoreNodeID: variationIDByCoreNodeID,
      parentVariationIDByCoreNodeID: parentVariationIDByCoreNodeID,
      fingerprintNodes: fingerprintNodes
    )
  }

  static func topologyFingerprint(
    rootLineage: UInt64,
    nodes: [(lineage: UInt64, parentLineage: UInt64?, ply: UInt32, move: Int)]
  ) -> UInt64 {
    var hash: UInt64 = 1_469_598_103_934_665_603
    func mix(_ value: UInt64) {
      hash ^= value
      hash &*= 1_099_511_628_211
    }
    mix(rootLineage)
    mix(UInt64(nodes.count))
    for node in nodes {
      mix(node.lineage)
      mix(node.parentLineage ?? UInt64.max)
      mix(UInt64(node.ply))
      mix(UInt64(bitPattern: Int64(node.move)))
    }
    return hash
  }

  private mutating func applyMetricsOnly(
    prepared: PreparedSnapshot,
    snapshot: QixiCoreSnapshot,
    currentID: String
  ) -> VariationApplyResult {
    var nextQuality: [String: Double] = [:]
    for node in prepared.nodes {
      let id = Self.coreVariationNodeID(node.lineageHash)
      if let delta = node.qualityDeltaPercent {
        nextQuality[id] = delta
      }
    }
    coreQualityDeltaByNodeID = nextQuality

    let previousCurrent = currentNodeID
    currentNodeID = currentID
    if previousCurrent != currentID {
      currentPathNodeIDs = pathNodeIDs(to: currentNodeID)
    } else if currentPathNodeIDs.last != currentID && !currentPathNodeIDs.contains(currentID) {
      currentPathNodeIDs = pathNodeIDs(to: currentNodeID)
    }
    // Keep fingerprint (topology unchanged).
    lastTopologyFingerprint = Self.topologyFingerprint(
      rootLineage: snapshot.rootLineageHash,
      nodes: prepared.fingerprintNodes
    )
    return .metricsOnly
  }

  private mutating func applySetDiff(
    prepared: PreparedSnapshot,
    snapshot: QixiCoreSnapshot,
    boardMove: (Int, String) -> BoardMove?,
    currentID: String,
    fingerprint: UInt64
  ) -> Bool {
    var nextRecords: [String: NodeRecord] = [:]
    var nextChildren: [String: [String]] = [:]
    var laneByCoreID: [UInt32: Int] = [:]
    var nextQuality: [String: Double] = [:]
    var nextRootRef: [String: QixiCoreRootReference] = [:]

    for node in prepared.nodes {
      let nodeID = Self.coreVariationNodeID(node.lineageHash)
      // Parent may be absent from the light-capped set (same as full rebuild).
      let parentID = node.parent.flatMap { prepared.variationIDByCoreNodeID[$0] }
      let siblingIndex = parentID.flatMap { nextChildren[$0]?.count } ?? 0
      let parentLane = node.parent.flatMap { laneByCoreID[$0] } ?? 0
      let lane = node.parent == nil
        ? 0
        : (siblingIndex == 0 ? parentLane : parentLane + (siblingIndex.isMultiple(of: 2) ? -siblingIndex : siblingIndex))
      let move = boardMove(node.moveFromParent, node.moveColor)
      // Prefer previous lane when parent and sibling slot unchanged for stability — lanes are
      // recomputed identically to full rebuild for parity.
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
      laneByCoreID[node.id] = lane
      nextRootRef[nodeID] = .lineage(node.lineageHash)
      if let delta = node.qualityDeltaPercent {
        nextQuality[nodeID] = delta
      }
    }

    guard nextRecords[currentID] != nil else { return false }

    records = nextRecords
    childIDsByParent = nextChildren
    coreRootReferenceByNodeID = nextRootRef
    coreQualityDeltaByNodeID = nextQuality
    currentNodeID = currentID
    currentPathNodeIDs = pathNodeIDs(to: currentNodeID)
    nextSequence = max(nextSequence, records.count + 1)
    lastTopologyFingerprint = fingerprint
    projectionUsesCoreIDs = true
    return true
  }

  private mutating func fullRebuild(
    from prepared: PreparedSnapshot,
    snapshot: QixiCoreSnapshot,
    boardMove: (Int, String) -> BoardMove?,
    currentID: String
  ) {
    var nextRecords: [String: NodeRecord] = [:]
    var nextChildren: [String: [String]] = [:]
    var laneByNode: [UInt32: Int] = [:]
    for node in prepared.nodes {
      let nodeID = Self.coreVariationNodeID(node.lineageHash)
      let parentID = node.parent.flatMap { prepared.variationIDByCoreNodeID[$0] }
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
    guard nextRecords[currentID] != nil else { return }
    records = nextRecords
    childIDsByParent = nextChildren
    coreRootReferenceByNodeID = Dictionary(
      uniqueKeysWithValues: prepared.nodes.map {
        (Self.coreVariationNodeID($0.lineageHash), QixiCoreRootReference.lineage($0.lineageHash))
      }
    )
    coreQualityDeltaByNodeID = Dictionary(
      uniqueKeysWithValues: prepared.nodes.compactMap { node in
        node.qualityDeltaPercent.map { (Self.coreVariationNodeID(node.lineageHash), $0) }
      }
    )
    currentNodeID = currentID
    currentPathNodeIDs = pathNodeIDs(to: currentNodeID)
    nextSequence = max(nextSequence, records.count + 1)
    lastTopologyFingerprint = Self.topologyFingerprint(
      rootLineage: snapshot.rootLineageHash,
      nodes: prepared.fingerprintNodes
    )
    projectionUsesCoreIDs = true
  }
}
