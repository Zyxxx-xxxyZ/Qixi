import Foundation

private struct LegalityMovePayload: Encodable {
  var color: String
  var x: Int?
  var y: Int?
  var pass: Bool?

  init(_ move: BoardMove) {
    color = move.color.rawValue
    x = move.x
    y = move.y
    pass = move.isPass ? true : nil
  }
}

private struct AnalysisRequestPayload: Encodable {
  var moves: [LegalityMovePayload]
  var rules: String?
  var maxVisits: Int
  var komi: Double
  var rootNoise: Double

  init(moves: [BoardMove], rules: String?) {
    self.moves = moves.map(LegalityMovePayload.init)
    self.rules = rules
    maxVisits = 1
    komi = 7.5
    rootNoise = 0.0
  }
}

private struct LegalityCase {
  var name: String
  var moves: [BoardMove]
  var rules: String? = nil
}

@main
struct BoardLegalityCrosscheckGenerator {
  static func main() throws {
    let cases: [LegalityCase] = [
      LegalityCase(name: "empty", moves: []),
      LegalityCase(name: "single-pass", moves: [BoardMove(pass: .black)]),
      LegalityCase(name: "explicit-chinese-rules", moves: [], rules: "Chinese"),
      LegalityCase(
        name: "simple-capture",
        moves: [
          BoardMove(color: .black, x: 1, y: 0),
          BoardMove(color: .white, x: 0, y: 0),
          BoardMove(color: .black, x: 0, y: 1),
        ]
      ),
      LegalityCase(
        name: "legal-repeated-coordinate-after-capture",
        moves: [
          BoardMove(color: .white, x: 1, y: 1),
          BoardMove(color: .black, x: 0, y: 1),
          BoardMove(color: .black, x: 1, y: 0),
          BoardMove(color: .black, x: 2, y: 1),
          BoardMove(color: .black, x: 1, y: 2),
          BoardMove(color: .black, x: 1, y: 1),
        ]
      ),
      LegalityCase(
        name: "occupied-point",
        moves: [
          BoardMove(color: .black, x: 3, y: 3),
          BoardMove(color: .white, x: 3, y: 3),
        ]
      ),
      LegalityCase(
        name: "suicide",
        moves: [
          BoardMove(color: .black, x: 0, y: 1),
          BoardMove(color: .black, x: 1, y: 0),
          BoardMove(color: .white, x: 0, y: 0),
        ]
      ),
      LegalityCase(
        name: "immediate-simple-ko-recapture",
        moves: [
          BoardMove(color: .black, x: 0, y: 1),
          BoardMove(color: .black, x: 1, y: 0),
          BoardMove(color: .black, x: 2, y: 1),
          BoardMove(color: .white, x: 1, y: 1),
          BoardMove(color: .white, x: 0, y: 2),
          BoardMove(color: .white, x: 2, y: 2),
          BoardMove(color: .white, x: 1, y: 3),
          BoardMove(color: .black, x: 1, y: 2),
          BoardMove(color: .white, x: 1, y: 1),
        ]
      ),
    ]

    let encoder = JSONEncoder()
    for testCase in cases {
      let legal = QixiBoardPosition.firstIllegalMoveIndex(in: testCase.moves) == nil
      let payload = AnalysisRequestPayload(moves: testCase.moves, rules: testCase.rules)
      let data = try encoder.encode(payload)
      let json = String(decoding: data, as: UTF8.self)
      print("\(testCase.name)\t\(legal ? "1" : "0")\t\(json)")
    }
  }
}
