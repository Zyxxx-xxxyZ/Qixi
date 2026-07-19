import Foundation
import CoreGraphics

/// Compare suggestedSelection normalized corners against ground_truth.json for needsupport easy*.png.
@main
struct BoardLocatorGTEval {
  static func main() throws {
    guard CommandLine.arguments.count >= 3 else {
      fputs("usage: board_locator_gt_eval <needsupport_dir> <ground_truth.json>\n", stderr)
      exit(2)
    }
    let supportDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let gtURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let gtData = try Data(contentsOf: gtURL)
    let gt = try JSONSerialization.jsonObject(with: gtData) as! [String: Any]

    var totalCornerErr = 0.0
    var totalCorners = 0
    var passCount = 0
    var failCount = 0
    // Pass if mean corner distance (normalized image diagonal units) < threshold
    // and max corner distance < maxThreshold.
    let meanPass: Double = 0.025
    let maxPass: Double = 0.045

    for name in gt.keys.sorted() {
      guard let entry = gt[name] as? [String: Any],
            let normalized = entry["normalized"] as? [String: Any] else {
        fputs("skip \(name): bad gt\n", stderr)
        continue
      }
      let imageURL = supportDir.appendingPathComponent("\(name).png")
      guard FileManager.default.fileExists(atPath: imageURL.path) else {
        fputs("skip \(name): missing image\n", stderr)
        continue
      }
      let data = try Data(contentsOf: imageURL)
      let selection = try QixiBoardImageRecognizer.suggestedSelection(from: data)

      let gtCorners = [
        point(normalized["topLeft"]),
        point(normalized["topRight"]),
        point(normalized["bottomRight"]),
        point(normalized["bottomLeft"])
      ]
      let predCorners = [
        selection.topLeft,
        selection.topRight,
        selection.bottomRight,
        selection.bottomLeft
      ]
      let labels = ["TL", "TR", "BR", "BL"]
      var sum = 0.0
      var mx = 0.0
      var parts: [String] = []
      for i in 0..<4 {
        let d = hypot(Double(predCorners[i].x - gtCorners[i].x), Double(predCorners[i].y - gtCorners[i].y))
        sum += d
        mx = max(mx, d)
        parts.append(String(format: "%@=%.4f", labels[i], d))
        totalCornerErr += d
        totalCorners += 1
      }
      let mean = sum / 4.0
      let ok = mean <= meanPass && mx <= maxPass
      if ok { passCount += 1 } else { failCount += 1 }
      let status = ok ? "PASS" : "FAIL"
      print(String(format: "%@ %@: mean=%.4f max=%.4f  [%@]", status, name, mean, mx, parts.joined(separator: " ")))
      print(String(
        format: "  pred TL=(%.4f,%.4f) TR=(%.4f,%.4f) BR=(%.4f,%.4f) BL=(%.4f,%.4f)",
        Double(selection.topLeft.x), Double(selection.topLeft.y),
        Double(selection.topRight.x), Double(selection.topRight.y),
        Double(selection.bottomRight.x), Double(selection.bottomRight.y),
        Double(selection.bottomLeft.x), Double(selection.bottomLeft.y)
      ))
    }

    let avg = totalCorners > 0 ? totalCornerErr / Double(totalCorners) : 0
    print(String(format: "SUMMARY pass=%d fail=%d avgCorner=%.4f (n=%d)", passCount, failCount, avg, totalCorners))
    if failCount > 0 { exit(1) }
  }

  private static func point(_ any: Any?) -> CGPoint {
    let arr = any as! [Double]
    return CGPoint(x: arr[0], y: arr[1])
  }
}
