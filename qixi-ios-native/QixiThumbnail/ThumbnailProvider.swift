import UIKit
import QuickLookThumbnailing

/// Provides Files / Quick Look icons for `.qixi-mcts` packages.
/// Prefer the board PNG written into the package; otherwise render from snapshot.json.
final class ThumbnailProvider: QLThumbnailProvider {
  private enum PackagePaths {
    static let quickLookThumbnail = "QuickLook/Thumbnail.png"
    static let rootThumbnail = "thumbnail.png"
    static let snapshot = "snapshot.json"
  }

  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
  ) {
    let packageURL = request.fileURL
    let access = packageURL.startAccessingSecurityScopedResource()
    defer {
      if access {
        packageURL.stopAccessingSecurityScopedResource()
      }
    }

    // 1) Prefer a pre-rendered board image inside the package.
    if let imageURL = firstExistingImageURL(in: packageURL) {
      let reply = QLThumbnailReply(imageFileURL: imageURL)
      reply.extensionBadge = "MCTS"
      handler(reply, nil)
      return
    }

    // 2) Fallback: draw from snapshot.json so older packages still get a board icon.
    let maxSide = max(request.maximumSize.width, request.maximumSize.height)
    let pixelSize = max(64, min(1024, maxSide.isFinite ? maxSide : 256))
    if let image = renderBoardFromSnapshot(in: packageURL, pixelSize: pixelSize) {
      let reply = QLThumbnailReply(
        contextSize: CGSize(width: pixelSize, height: pixelSize),
        currentContextDrawing: {
          image.draw(in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
          return true
        }
      )
      reply.extensionBadge = "MCTS"
      handler(reply, nil)
      return
    }

    // 3) Last resort: empty board grid so icons still differ from a plain document glyph.
    let reply = QLThumbnailReply(
      contextSize: CGSize(width: pixelSize, height: pixelSize),
      currentContextDrawing: {
        BoardThumbnailDrawer.draw(stones: [], pixelSize: pixelSize)
        return true
      }
    )
    reply.extensionBadge = "MCTS"
    handler(reply, nil)
  }

  private func firstExistingImageURL(in packageURL: URL) -> URL? {
    let candidates = [
      packageURL.appendingPathComponent(PackagePaths.quickLookThumbnail, isDirectory: false),
      packageURL.appendingPathComponent(PackagePaths.rootThumbnail, isDirectory: false),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return nil
  }

  private func renderBoardFromSnapshot(in packageURL: URL, pixelSize: CGFloat) -> UIImage? {
    let snapshotURL = packageURL.appendingPathComponent(PackagePaths.snapshot, isDirectory: false)
    guard let data = try? Data(contentsOf: snapshotURL),
          let snapshot = try? JSONDecoder().decode(ThumbnailSnapshot.self, from: data)
    else {
      return nil
    }
    let ply = min(max(0, snapshot.currentPly), snapshot.mainLine.count)
    let moves = Array(snapshot.mainLine.prefix(ply))
    let stones = BoardThumbnailDrawer.visibleStones(
      moves: moves,
      setup: snapshot.recognizedSetupStones ?? []
    )
    return BoardThumbnailDrawer.render(stones: stones, pixelSize: pixelSize)
  }
}

// MARK: - Minimal snapshot model (extension-local; no app linkage)

private struct ThumbnailSnapshot: Decodable {
  var currentPly: Int
  var mainLine: [ThumbnailMove]
  var recognizedSetupStones: [ThumbnailSetupStone]?
}

private struct ThumbnailMove: Decodable {
  var color: String
  var x: Int?
  var y: Int?
  var isPass: Bool
}

private struct ThumbnailSetupStone: Decodable {
  var color: String
  var x: Int
  var y: Int
}

private struct ThumbnailStone {
  var isBlack: Bool
  var x: Int
  var y: Int
}

// MARK: - Lightweight board draw + capture-aware replay

private enum BoardThumbnailDrawer {
  static let boardSize = 19

  static func render(stones: [ThumbnailStone], pixelSize: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = true
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: pixelSize, height: pixelSize),
      format: format
    )
    return renderer.image { _ in
      draw(stones: stones, pixelSize: pixelSize)
    }
  }

  static func draw(stones: [ThumbnailStone], pixelSize: CGFloat) {
    guard let cg = UIGraphicsGetCurrentContext() else { return }
    UIColor(red: 0.86, green: 0.70, blue: 0.45, alpha: 1).setFill()
    cg.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

    let margin = pixelSize * 0.08
    let gridSpan = pixelSize - margin * 2
    let step = boardSize > 1 ? gridSpan / CGFloat(boardSize - 1) : gridSpan
    UIColor(white: 0.15, alpha: 0.85).setStroke()
    cg.setLineWidth(max(1, pixelSize / 220))
    for i in 0..<boardSize {
      let p = margin + CGFloat(i) * step
      cg.move(to: CGPoint(x: margin, y: p))
      cg.addLine(to: CGPoint(x: margin + gridSpan, y: p))
      cg.move(to: CGPoint(x: p, y: margin))
      cg.addLine(to: CGPoint(x: p, y: margin + gridSpan))
    }
    cg.strokePath()

    if boardSize == 19 {
      let stars = [3, 9, 15]
      UIColor(white: 0.12, alpha: 0.9).setFill()
      let r = max(1.2, step * 0.12)
      for y in stars {
        for x in stars {
          let c = CGPoint(x: margin + CGFloat(x) * step, y: margin + CGFloat(y) * step)
          cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
      }
    }

    let stoneR = step * 0.46
    for stone in stones {
      let c = CGPoint(
        x: margin + CGFloat(stone.x) * step,
        y: margin + CGFloat(stone.y) * step
      )
      let rect = CGRect(x: c.x - stoneR, y: c.y - stoneR, width: stoneR * 2, height: stoneR * 2)
      if stone.isBlack {
        UIColor.black.setFill()
        cg.fillEllipse(in: rect)
      } else {
        UIColor.white.setFill()
        cg.fillEllipse(in: rect)
        UIColor(white: 0.2, alpha: 0.55).setStroke()
        cg.setLineWidth(max(1, pixelSize / 280))
        cg.strokeEllipse(in: rect)
      }
    }
  }

  /// Replay moves with simple multi-stone capture (enough for a recognizable icon).
  static func visibleStones(moves: [ThumbnailMove], setup: [ThumbnailSetupStone]) -> [ThumbnailStone] {
    var board = Array(repeating: Optional<Bool>.none, count: boardSize * boardSize) // true = black
    for stone in setup where isOnBoard(stone.x, stone.y) {
      board[index(stone.x, stone.y)] = stone.color.uppercased().hasPrefix("B")
    }
    for move in moves {
      if move.isPass { continue }
      guard let x = move.x, let y = move.y, isOnBoard(x, y) else { continue }
      let isBlack = move.color.uppercased().hasPrefix("B")
      let point = index(x, y)
      if board[point] != nil { continue }
      board[point] = isBlack
      // Capture opposite groups with no liberty.
      let opp = !isBlack
      for (nx, ny) in neighbors(x, y) {
        guard isOnBoard(nx, ny), board[index(nx, ny)] == opp else { continue }
        let group = connectedGroup(at: nx, y: ny, color: opp, board: board)
        if !groupHasLiberty(group, board: board) {
          for p in group { board[p] = nil }
        }
      }
      // Suicide: remove own group if it has no liberty (illegal positions shouldn't appear).
      let own = connectedGroup(at: x, y: y, color: isBlack, board: board)
      if !groupHasLiberty(own, board: board) {
        for p in own { board[p] = nil }
      }
    }
    var stones: [ThumbnailStone] = []
    for (i, color) in board.enumerated() {
      guard let isBlack = color else { continue }
      stones.append(ThumbnailStone(isBlack: isBlack, x: i % boardSize, y: i / boardSize))
    }
    return stones
  }

  private static func isOnBoard(_ x: Int, _ y: Int) -> Bool {
    x >= 0 && x < boardSize && y >= 0 && y < boardSize
  }

  private static func index(_ x: Int, _ y: Int) -> Int { y * boardSize + x }

  private static func neighbors(_ x: Int, _ y: Int) -> [(Int, Int)] {
    [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
  }

  private static func connectedGroup(
    at x: Int,
    y: Int,
    color: Bool,
    board: [Bool?]
  ) -> [Int] {
    var result: [Int] = []
    var stack = [(x, y)]
    var seen = Set<Int>()
    while let (cx, cy) = stack.popLast() {
      guard isOnBoard(cx, cy) else { continue }
      let p = index(cx, cy)
      guard !seen.contains(p), board[p] == color else { continue }
      seen.insert(p)
      result.append(p)
      for n in neighbors(cx, cy) {
        stack.append(n)
      }
    }
    return result
  }

  private static func groupHasLiberty(_ group: [Int], board: [Bool?]) -> Bool {
    for p in group {
      let x = p % boardSize
      let y = p / boardSize
      for (nx, ny) in neighbors(x, y) where isOnBoard(nx, ny) {
        if board[index(nx, ny)] == nil { return true }
      }
    }
    return false
  }
}
