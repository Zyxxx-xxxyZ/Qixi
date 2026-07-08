import Foundation

@main
struct BoardPhotoLocatorSmoke {
  static func main() throws {
    guard CommandLine.arguments.count > 1 else {
      fputs("usage: board_photo_locator_smoke <photo> [photo ...]\n", stderr)
      exit(2)
    }

    for path in CommandLine.arguments.dropFirst() {
      let url = URL(fileURLWithPath: path)
      let data = try Data(contentsOf: url)
      let selection = try QixiBoardImageRecognizer.suggestedSelection(from: data)
      let result = try QixiBoardImageRecognizer.recognizeBoard(from: data, selection: selection)
      let blackCount = result.stones.filter { $0.color == .black }.count
      let whiteCount = result.stones.filter { $0.color == .white }.count
      print(
        "\(url.lastPathComponent): stones=\(result.stones.count) black=\(blackCount) white=\(whiteCount) " +
          "selection=\(format(selection.topLeft)) \(format(selection.topRight)) \(format(selection.bottomRight)) \(format(selection.bottomLeft))"
      )
      expect(selectionDistance(selection, QixiBoardImageSelection.defaultGrid) > 0.015, "\(path): auto locator returned the default grid")
      expect(result.gridX.count == 19 && result.gridY.count == 19, "\(path): selected board should rectify to a 19x19 grid")
      expect(result.stones.count >= 8 && result.stones.count <= 90, "\(path): implausible recognized stone count \(result.stones.count)")
    }
  }

  private static func selectionDistance(_ lhs: QixiBoardImageSelection, _ rhs: QixiBoardImageSelection) -> Double {
    pointDistance(lhs.topLeft, rhs.topLeft) +
      pointDistance(lhs.topRight, rhs.topRight) +
      pointDistance(lhs.bottomRight, rhs.bottomRight) +
      pointDistance(lhs.bottomLeft, rhs.bottomLeft)
  }

  private static func pointDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
    let dx = Double(lhs.x - rhs.x)
    let dy = Double(lhs.y - rhs.y)
    return sqrt(dx * dx + dy * dy)
  }

  private static func format(_ point: CGPoint) -> String {
    String(format: "%.4f,%.4f", Double(point.x), Double(point.y))
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fputs("Board photo locator smoke failed: \(message)\n", stderr)
      exit(1)
    }
  }
}
