import Foundation

@main
struct BoardRecognitionSmoke {
  static func main() throws {
    guard CommandLine.arguments.count == 11 else {
      fputs("usage: board_recognition_smoke <empty.png> <standard.png> <dimmed.png> <dense.png> <padded.png> <rotated.png> <perspective.png> <glare.png> <large.png> <exif-oriented.jpg>\n", stderr)
      exit(2)
    }
    try runCase(
      name: "empty",
      path: CommandLine.arguments[1],
      expected: [:]
    )
    let standard: [String: StoneColor] = [
      "3,3": .black,
      "15,3": .white,
      "10,10": .black,
      "16,16": .white
    ]
    try runCase(name: "standard", path: CommandLine.arguments[2], expected: standard)
    try runCase(name: "dimmed", path: CommandLine.arguments[3], expected: standard)
    try runCase(
      name: "dense",
      path: CommandLine.arguments[4],
      expected: [
        "3,3": .black,
        "15,3": .white,
        "10,10": .black,
        "16,16": .white,
        "4,15": .black,
        "14,4": .white,
        "16,10": .black,
        "10,16": .white
      ]
    )
    try runCase(name: "padded", path: CommandLine.arguments[5], expected: standard)
    try runCase(name: "rotated", path: CommandLine.arguments[6], expected: standard)
    try runCase(name: "perspective", path: CommandLine.arguments[7], expected: standard)
    try runCase(name: "glare", path: CommandLine.arguments[8], expected: standard)
    try runCase(name: "large", path: CommandLine.arguments[9], expected: standard)
    try runCase(name: "exif-oriented", path: CommandLine.arguments[10], expected: standard)
    try expectOversizedDataRejected()
    try expectOversizedURLRejected()
    try expectSymbolicLinkURLRejected(targetPath: CommandLine.arguments[2])
    try expectDirectoryURLRejected()
    print("Board recognition smoke passed")
  }

  static func runCase(name: String, path: String, expected: [String: StoneColor]) throws {
    let url = URL(fileURLWithPath: path)
    let result = try QixiBoardImageRecognizer.recognizeBoard(from: url)
    let stones = Dictionary(uniqueKeysWithValues: result.stones.map { stone in
      ("\(stone.x),\(stone.y)", stone.color)
    })

    expect(result.gridX.count == 19 && result.gridY.count == 19, "\(name): 19x19 grid detected")
    expect(stones.count == expected.count, "\(name): expected exactly \(expected.count) stones, got \(stones.count): \(stones)")
    for (point, color) in expected {
      expect(stones[point] == color, "\(name): \(color) stone at \(point)")
    }
  }

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fputs("Board recognition smoke failed: \(message)\n", stderr)
      exit(1)
    }
  }

  static func expectOversizedDataRejected() throws {
    do {
      _ = try QixiBoardImageRecognizer.recognizeBoard(
        from: Data(count: Int(QixiBoardImageRecognizer.maxInputImageBytes) + 1)
      )
      fail("oversized image Data should be rejected before ImageIO decode")
    } catch QixiBoardImageRecognizer.RecognitionError.imageTooLarge(let bytes, let limit) {
      expect(
        bytes == QixiBoardImageRecognizer.maxInputImageBytes + 1 &&
          limit == QixiBoardImageRecognizer.maxInputImageBytes,
        "oversized image Data error reports exact byte budget"
      )
    } catch {
      fail("unexpected oversized image Data error: \(error)")
    }
  }

  static func expectOversizedURLRejected() throws {
    let oversizedURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("qixi-oversized-board-photo.bin")
    FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: oversizedURL) }
    let handle = try FileHandle(forWritingTo: oversizedURL)
    try handle.truncate(atOffset: QixiBoardImageRecognizer.maxInputImageBytes + 1)
    handle.closeFile()

    do {
      _ = try QixiBoardImageRecognizer.recognizeBoard(from: oversizedURL)
      fail("oversized image URL should be rejected before file data is loaded")
    } catch QixiBoardImageRecognizer.RecognitionError.imageTooLarge(let bytes, let limit) {
      expect(
        bytes == QixiBoardImageRecognizer.maxInputImageBytes + 1 &&
          limit == QixiBoardImageRecognizer.maxInputImageBytes,
        "oversized image URL error reports exact byte budget"
      )
    } catch {
      fail("unexpected oversized image URL error: \(error)")
    }
  }

  static func expectSymbolicLinkURLRejected(targetPath: String) throws {
    let linkedURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("qixi-linked-board-photo.png")
    try? FileManager.default.removeItem(at: linkedURL)
    defer { try? FileManager.default.removeItem(at: linkedURL) }
    try FileManager.default.createSymbolicLink(
      at: linkedURL,
      withDestinationURL: URL(fileURLWithPath: targetPath)
    )

    do {
      _ = try QixiBoardImageRecognizer.recognizeBoard(from: linkedURL)
      fail("symbolic-link image URL should be rejected before ImageIO decode")
    } catch QixiBoardImageRecognizer.RecognitionError.symbolicLink(let path) {
      expect(path == linkedURL.path, "symbolic-link image URL error reports the linked path")
    } catch {
      fail("unexpected symbolic-link image URL error: \(error)")
    }
  }

  static func expectDirectoryURLRejected() throws {
    let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("qixi-board-photo-directory", isDirectory: true)
    try? FileManager.default.removeItem(at: directoryURL)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    do {
      _ = try QixiBoardImageRecognizer.recognizeBoard(from: directoryURL)
      fail("directory image URL should be rejected before ImageIO decode")
    } catch QixiBoardImageRecognizer.RecognitionError.notRegularFile(let path) {
      expect(path == directoryURL.path, "directory image URL error reports the directory path")
    } catch {
      fail("unexpected directory image URL error: \(error)")
    }
  }

  static func fail(_ message: String) -> Never {
    fputs("Board recognition smoke failed: \(message)\n", stderr)
    exit(1)
  }
}
