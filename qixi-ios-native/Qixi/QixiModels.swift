import Foundation
import SwiftUI

enum QixiAnalysisLimits {
  static let minMaxVisits = 1
  static let maxMaxVisits = 200_000
  static let minKomi = -150.0
  static let maxKomi = 150.0
  static let defaultKomi = 7.5
  /// Hard floor for valid wide-root-noise (0 disables extra root exploration).
  static let minRootNoise = 0.0
  /// First-launch / missing-preference product default.
  static let defaultRootNoise = 0.04
  /// Soft upper bound for the main-page wide-root-noise number field.
  static let uiMaxRootNoise = 2.0

  static func isValidMaxVisits(_ value: Int) -> Bool {
    value >= minMaxVisits && value <= maxMaxVisits
  }

  static func isValidKomi(_ value: Double) -> Bool {
    value.isFinite && value >= minKomi && value <= maxKomi
  }

  static func isValidRootNoise(_ value: Double) -> Bool {
    value.isFinite && value >= minRootNoise
  }

  static func normalizedKomi(_ value: Double) -> Double {
    guard value.isFinite else { return defaultKomi }
    return min(max(value, minKomi), maxKomi)
  }

  static func normalizedRootNoise(_ value: Double) -> Double {
    guard value.isFinite else { return defaultRootNoise }
    return max(minRootNoise, value)
  }
}

enum QixiRules {
  static let fixedRules = "Chinese"
}

enum StoneColor: String, Codable {
  case black = "B"
  case white = "W"
}

struct BoardMove: Identifiable, Codable, Equatable {
  let id = UUID()
  var color: StoneColor
  var x: Int?
  var y: Int?
  var isPass: Bool

  init(color: StoneColor, x: Int, y: Int) {
    self.color = color
    self.x = x
    self.y = y
    self.isPass = false
  }

  init(pass color: StoneColor) {
    self.color = color
    self.x = nil
    self.y = nil
    self.isPass = true
  }

  enum CodingKeys: String, CodingKey {
    case color, x, y, isPass
  }

  static func == (lhs: BoardMove, rhs: BoardMove) -> Bool {
    lhs.color == rhs.color &&
      lhs.x == rhs.x &&
      lhs.y == rhs.y &&
      lhs.isPass == rhs.isPass
  }
}

struct BoardSetupStone: Identifiable, Codable, Equatable {
  var id: Int { y * QixiBoardPosition.boardSize + x }
  var color: StoneColor
  var x: Int
  var y: Int
}

struct EngineRequest: Encodable {
  var engine: String
}

struct MovePayload: Encodable {
  var color: String
  var x: Int?
  var y: Int?
  var pass: Bool?

  init(move: BoardMove) {
    self.color = move.color.rawValue
    self.x = move.x
    self.y = move.y
    self.pass = move.isPass ? true : nil
  }
}

struct AnalysisRequest: Encodable {
  var moves: [MovePayload]
  var setupStones: [BoardSetupStone] = []
  var nextPlayer: String
  var rules: String = QixiRules.fixedRules
  var maxVisits: Int
  var komi: Double
  var rootNoise: Double

  init(
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double,
    rootToMove: StoneColor = .black
  ) {
    self.moves = moves.map(MovePayload.init(move:))
    self.setupStones = setupStones
    self.nextPlayer = QixiBoardPosition.nextPlayer(after: moves, rootToMove: rootToMove).rawValue
    self.maxVisits = maxVisits
    self.komi = komi
    self.rootNoise = rootNoise
  }
}

struct BackendStatusResponse: Decodable {
  var engine: String
  var engineId: String?
  var state: String
  var running: Bool
  var paused: Bool
}

struct AnalysisResponse: Decodable {
  var engine: String
  var state: String
  var positionKey: String
  var winrate: Double?
  var scoreMean: Double?
  var visits: Int?
  var moves: [AnalysisMove]
  var ownership: [Double]
}

struct AnalysisMove: Decodable {
  var x: Int
  var y: Int
  var move: String?
  var visits: Int?
  var winrate: Double?
  var scoreMean: Double?
}

struct VisibleBoardStone: Identifiable, Equatable {
  var id: Int { y * 19 + x }
  var color: StoneColor
  var x: Int
  var y: Int
}

enum QixiBoardPosition {
  static let boardSize = 19

  static func visibleStones(
    after moves: [BoardMove],
    setupStones: [BoardSetupStone] = []
  ) -> [VisibleBoardStone] {
    let board = replay(moves, setupStones: setupStones)
    return board.enumerated().compactMap { index, color in
      guard let color else { return nil }
      return VisibleBoardStone(color: color, x: index % boardSize, y: index / boardSize)
    }
  }

  static func isOccupied(
    after moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    x: Int,
    y: Int
  ) -> Bool {
    guard isOnBoard(x: x, y: y) else { return false }
    return replay(moves, setupStones: setupStones)[index(x: x, y: y)] != nil
  }

  static func capturedStoneIDsByPlaying(
    _ move: BoardMove,
    after moves: [BoardMove],
    setupStones: [BoardSetupStone] = []
  ) -> [Int] {
    guard !move.isPass, let x = move.x, let y = move.y else { return [] }
    let replayState = replayState(after: moves, setupStones: setupStones)
    guard let candidate = nextBoard(afterPlaying: replayState.board, color: move.color, x: x, y: y) else {
      return []
    }
    if let previousBoard = replayState.previousBoard,
       candidate == previousBoard {
      return []
    }
    var captured: [Int] = []
    captured.reserveCapacity(4)
    for point in 0..<(boardSize * boardSize) where replayState.board[point] != nil && candidate[point] == nil {
      captured.append(point)
    }
    return captured
  }

  static func isLegalMove(
    after moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    x: Int,
    y: Int,
    color: StoneColor
  ) -> Bool {
    let replayState = replayState(after: moves, setupStones: setupStones)
    guard let candidate = nextBoard(afterPlaying: replayState.board, color: color, x: x, y: y)
    else {
      return false
    }
    if let previousBoard = replayState.previousBoard,
       candidate == previousBoard {
      return false
    }
    return true
  }

  static func firstIllegalMoveIndex(
    in moves: [BoardMove],
    setupStones: [BoardSetupStone] = []
  ) -> Int? {
    var board = board(from: setupStones)
    var previousBoard: [StoneColor?]?
    for (index, move) in moves.enumerated() {
      if move.isPass {
        previousBoard = board
        continue
      }
      guard let x = move.x, let y = move.y,
            let candidate = nextBoard(afterPlaying: board, color: move.color, x: x, y: y) else {
        return index
      }
      if let previousBoard,
         candidate == previousBoard {
        return index
      }
      previousBoard = board
      board = candidate
    }
    return nil
  }

  static func firstInvalidSetupStoneIndex(in setupStones: [BoardSetupStone]) -> Int? {
    var seen = Array(repeating: false, count: boardSize * boardSize)
    for (index, stone) in setupStones.enumerated() {
      guard isOnBoard(x: stone.x, y: stone.y) else { return index }
      let point = self.index(x: stone.x, y: stone.y)
      guard !seen[point] else { return index }
      seen[point] = true
    }
    return nil
  }

  /// Side to move after `moves`.
  /// - Parameter rootToMove: Color to play when `moves` is empty (root). Defaults to Black.
  ///   Pass the first move color of the current line when the game can start with White
  ///   (SGF setup + W first, some handicap-style dumps). Bare even/odd ply is not sufficient.
  static func nextPlayer(
    after moves: [BoardMove],
    rootToMove: StoneColor = .black
  ) -> StoneColor {
    guard let last = moves.last else { return rootToMove }
    return last.color == .black ? .white : .black
  }

  private static func replay(
    _ moves: [BoardMove],
    setupStones: [BoardSetupStone]
  ) -> [StoneColor?] {
    replayState(after: moves, setupStones: setupStones).board
  }

  private struct BoardReplayState {
    var board: [StoneColor?]
    var previousBoard: [StoneColor?]?
  }

  private static func replayState(
    after moves: [BoardMove],
    setupStones: [BoardSetupStone]
  ) -> BoardReplayState {
    var state = BoardReplayState(board: board(from: setupStones), previousBoard: nil)
    for move in moves {
      if move.isPass {
        state.previousBoard = state.board
        continue
      }
      guard let x = move.x, let y = move.y, isOnBoard(x: x, y: y) else { continue }
      if let nextBoard = nextBoard(afterPlaying: state.board, color: move.color, x: x, y: y) {
        state.previousBoard = state.board
        state.board = nextBoard
      }
    }
    return state
  }

  private static func board(from setupStones: [BoardSetupStone]) -> [StoneColor?] {
    var board = emptyBoard()
    for stone in setupStones where isOnBoard(x: stone.x, y: stone.y) {
      board[index(x: stone.x, y: stone.y)] = stone.color
    }
    return board
  }

  private static func emptyBoard() -> [StoneColor?] {
    Array<StoneColor?>(repeating: nil, count: boardSize * boardSize)
  }

  private static let neighborTable: [[Int]] = (0..<(boardSize * boardSize)).map { point in
    let x = point % boardSize
    let y = point / boardSize
    var values: [Int] = []
    values.reserveCapacity(4)
    if x > 0 { values.append(point - 1) }
    if x + 1 < boardSize { values.append(point + 1) }
    if y > 0 { values.append(point - boardSize) }
    if y + 1 < boardSize { values.append(point + boardSize) }
    return values
  }

  private static func nextBoard(afterPlaying board: [StoneColor?], color: StoneColor, x: Int, y: Int) -> [StoneColor?]? {
    guard isOnBoard(x: x, y: y) else { return nil }
    let point = index(x: x, y: y)
    guard board[point] == nil else { return nil }

    var nextBoard = board
    nextBoard[point] = color
    let opponent: StoneColor = color == .black ? .white : .black
    for neighbor in neighbors(of: point) where nextBoard[neighbor] == opponent {
      let group = group(from: neighbor, board: nextBoard)
      if !hasLiberty(group, board: nextBoard) {
        for captured in group {
          nextBoard[captured] = nil
        }
      }
    }

    let ownGroup = group(from: point, board: nextBoard)
    guard hasLiberty(ownGroup, board: nextBoard) else { return nil }
    return nextBoard
  }

  private static func group(from start: Int, board: [StoneColor?]) -> [Int] {
    guard let color = board[start] else { return [] }
    var visited = Array(repeating: false, count: boardSize * boardSize)
    var group: [Int] = []
    var stack = [start]
    while let point = stack.popLast() {
      guard !visited[point] else { continue }
      visited[point] = true
      group.append(point)
      for neighbor in neighbors(of: point) where board[neighbor] == color && !visited[neighbor] {
        stack.append(neighbor)
      }
    }
    return group
  }

  private static func hasLiberty(_ group: [Int], board: [StoneColor?]) -> Bool {
    for point in group {
      for neighbor in neighbors(of: point) where board[neighbor] == nil {
        return true
      }
    }
    return false
  }

  private static func neighbors(of index: Int) -> [Int] {
    neighborTable[index]
  }

  private static func index(x: Int, y: Int) -> Int {
    y * boardSize + x
  }

  private static func isOnBoard(x: Int, y: Int) -> Bool {
    x >= 0 && x < boardSize && y >= 0 && y < boardSize
  }
}

struct CandidateMove: Identifiable, Codable, Equatable {
  var id: Int { y * 19 + x }
  var x: Int
  var y: Int
  var rank: Int
  var winrate: Double
  var visits: Int
  var scoreMean: Double

  var winratePercent: Double {
    winrate * 100.0
  }

  enum CodingKeys: String, CodingKey {
    case x, y, rank, winrate, visits, scoreMean
  }
}

struct CandidateColorComponents: Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  var color: Color {
    Color(red: red, green: green, blue: blue, opacity: alpha)
  }
}

struct VisibleCandidateOverlay: Identifiable, Equatable {
  var id: Int { y * 19 + x }
  var x: Int
  var y: Int
  var rankText: String
  var winrateText: String
  var visitsText: String
  var scoreText: String
  var colorComponents: CandidateColorComponents?
  var continuationRingColor: StoneColor? = nil
  var showsAnalysisText: Bool = true
  var usesStoneSizedContinuationMarker: Bool = false
  /// 0…1 presentation weight for enter/exit color gradients (1 = fully in display set).
  var presentationWeight: Double = 1.0
}

struct TerritoryPoint: Identifiable, Codable, Equatable {
  var id: Int { y * 19 + x }
  var x: Int
  var y: Int
  var ownership: Double

  enum CodingKeys: String, CodingKey {
    case x, y, ownership
  }
}

enum AnalysisEngine: String, CaseIterable, Codable, Identifiable {
  case none
  case b6
  case b18nbt
  case b28nbt

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: return L10n.text(.engineNone)
    case .b6: return L10n.text(.engineB6)
    case .b18nbt: return L10n.text(.engineB18)
    case .b28nbt: return L10n.text(.engineB28)
    }
  }

  var symbolName: String {
    switch self {
    case .none: return "power"
    case .b6: return "cpu"
    case .b18nbt: return "point.3.connected.trianglepath.dotted"
    case .b28nbt: return "server.rack"
    }
  }
}

enum HermesStatus {
  case ready
  case loading
  case offline

  init?(automationValue: String?) {
    guard let normalized = automationValue?.lowercased() else { return nil }
    switch normalized {
    case "ready": self = .ready
    case "loading": self = .loading
    case "offline": self = .offline
    default: return nil
    }
  }

  var title: String {
    switch self {
    case .ready: return L10n.text(.hermesReady)
    case .loading: return L10n.text(.hermesLoading)
    case .offline: return L10n.text(.hermesOffline)
    }
  }

  var color: Color {
    switch self {
    case .ready: return QixiColor.hermesBlue
    case .loading: return QixiColor.hermesOrange
    case .offline: return QixiColor.hermesRed
    }
  }
}

enum QixiUtilitySheet: String, Identifiable {
  case camera
  case importGame
  case sync
  case exportShare

  var id: String { rawValue }

  init?(automationValue: String?) {
    guard let automationValue else { return nil }
    switch automationValue {
    case "camera": self = .camera
    case "import": self = .importGame
    case "sync": self = .sync
    case "export", "exportShare": self = .exportShare
    default: return nil
    }
  }
}

enum QixiUnsavedChoice {
  case save
  case discard
  case cancel
}

enum QixiUnsavedKind: Equatable {
  case newGame
  case openSheet
  case openArchive(QixiSyncStore.ArchiveListItem)
  case appBackground
}

struct QixiUnsavedChangesDecision: Identifiable, Equatable {
  let id = UUID()
  var kind: QixiUnsavedKind
}

struct ChartPoint: Identifiable {
  var id: Int { ply }
  var ply: Int
  var winrate: Double
  var scoreMean: Double
}

struct VariationNode: Identifiable, Equatable {
  var id: String
  var ply: Int
  var lane: Int
  var qualityDeltaPercent: Double?
  var isInitial: Bool = false
}

struct VariationEdge: Identifiable, Equatable {
  var id: String { "\(from)-\(to)" }
  var from: String
  var to: String
}

struct VariationTree: Equatable {
  var nodes: [VariationNode]
  var edges: [VariationEdge]
  var currentNodeID: String = "root"
}

enum NumberText {
  static func winrate(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100.0)
  }

  static func score(_ value: Double) -> String {
    String(format: "%+.1f", value)
  }
}

enum QixiColor {
  static let background = Color(red: 0.916, green: 0.890, blue: 0.832)
  static let controlSurface = background
  static let controlSurfacePressed = Color(red: 0.884, green: 0.856, blue: 0.790)
  static let ink = Color(red: 0.098, green: 0.105, blue: 0.132)
  static let muted = Color(red: 0.470, green: 0.494, blue: 0.548)
  static let separator = Color(red: 0.130, green: 0.140, blue: 0.165).opacity(0.22)
  static let separatorStrong = Color(red: 0.130, green: 0.140, blue: 0.165).opacity(0.46)
  static let hermesBlue = Color(red: 0.129, green: 0.322, blue: 0.957)
  static let hermesOrange = Color(red: 0.996, green: 0.604, blue: 0.000)
  static let hermesRed = Color(red: 0.780, green: 0.180, blue: 0.302)
  static let warningRed = Color(red: 0.760, green: 0.128, blue: 0.196)
  static let successGreen = Color(red: 0.145, green: 0.647, blue: 0.416)
}
