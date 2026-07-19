import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Renders a simple final-position board thumbnail for archive previews / package icons.
enum QixiBoardThumbnailRenderer {
  static let defaultPixelSize: CGFloat = 320
  /// Files / Quick Look package icons look best at ≥512; 1024 matches Apple's thumbnail dictionary key.
  static let packageIconPixelSize: CGFloat = 1024

  /// Moves that define the archived board picture: position at `currentPly` on the main line
  /// (falls back to the full line when ply is at/past the end).
  static func movesForThumbnail(mainLine: [BoardMove], currentPly: Int) -> [BoardMove] {
    let ply = min(max(0, currentPly), mainLine.count)
    if ply >= mainLine.count { return mainLine }
    return Array(mainLine.prefix(ply))
  }

  #if canImport(UIKit)
  static func render(
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    pixelSize: CGFloat = defaultPixelSize
  ) -> UIImage {
    let boardSize = QixiBoardPosition.boardSize
    let stones = QixiBoardPosition.visibleStones(after: moves, setupStones: setupStones)
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = true
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixelSize, height: pixelSize), format: format)
    return renderer.image { ctx in
      let cg = ctx.cgContext
      // Board wood
      UIColor(red: 0.86, green: 0.70, blue: 0.45, alpha: 1).setFill()
      cg.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

      let margin = pixelSize * 0.08
      let gridSpan = pixelSize - margin * 2
      let step = boardSize > 1 ? gridSpan / CGFloat(boardSize - 1) : gridSpan
      let line = UIColor(white: 0.15, alpha: 0.85)
      line.setStroke()
      cg.setLineWidth(max(1, pixelSize / 220))
      for i in 0..<boardSize {
        let p = margin + CGFloat(i) * step
        cg.move(to: CGPoint(x: margin, y: p))
        cg.addLine(to: CGPoint(x: margin + gridSpan, y: p))
        cg.move(to: CGPoint(x: p, y: margin))
        cg.addLine(to: CGPoint(x: p, y: margin + gridSpan))
      }
      cg.strokePath()

      // Star points (19×19)
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
        if stone.color == .black {
          UIColor.black.setFill()
        } else {
          UIColor.white.setFill()
          UIColor(white: 0.2, alpha: 0.55).setStroke()
          cg.setLineWidth(max(1, pixelSize / 280))
          cg.fillEllipse(in: rect)
          cg.strokeEllipse(in: rect)
          continue
        }
        cg.fillEllipse(in: rect)
      }
    }
  }

  static func pngData(
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    pixelSize: CGFloat = defaultPixelSize
  ) -> Data? {
    render(moves: moves, setupStones: setupStones, pixelSize: pixelSize).pngData()
  }
  #endif

  /// Best-effort package icon stamp for destinations that honor custom file icons.
  /// On iOS, `URLResourceValues.thumbnailDictionary` is get-only, so the durable
  /// Files/Quick Look cue is `QuickLook/Thumbnail.png` written into the package.
  /// This helper only ensures that path exists after a copy (when the source already
  /// had a root `thumbnail.png` but no Quick Look folder).
  static func applyStoredPackageIcon(in packageURL: URL) {
    let qlDir = packageURL
      .appendingPathComponent("QuickLook", isDirectory: true)
    let qlThumb = qlDir
      .appendingPathComponent("Thumbnail.png", isDirectory: false)
    if FileManager.default.fileExists(atPath: qlThumb.path) {
      return
    }
    let rootThumb = packageURL.appendingPathComponent("thumbnail.png", isDirectory: false)
    guard FileManager.default.fileExists(atPath: rootThumb.path) else { return }
    try? FileManager.default.createDirectory(at: qlDir, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: rootThumb, to: qlThumb)
  }

  static func applyPackageIcon(fromPNGData data: Data, to packageURL: URL) {
    // Ensure Quick Look path is present even if writeThumbnailPNG was skipped or
    // only root thumbnail.png was produced by an older code path.
    let qlDir = packageURL.appendingPathComponent("QuickLook", isDirectory: true)
    let qlThumb = qlDir.appendingPathComponent("Thumbnail.png", isDirectory: false)
    if !FileManager.default.fileExists(atPath: qlThumb.path) {
      try? FileManager.default.createDirectory(at: qlDir, withIntermediateDirectories: true)
      try? data.write(to: qlThumb, options: [.atomic])
    }
  }
}
