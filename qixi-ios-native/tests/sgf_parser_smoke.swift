import Foundation

@main
struct SGFParserSmoke {
  static func main() throws {
    let sgf = "(;GM[1]FF[4]SZ[19]KM[7.5]C[escaped\\]comment];B[pd];W[dd](;B[qq])(;B[cc]);B[])"
    let moves = try QixiSGFParser.parseMainLineMoves(from: sgf)
    expect(moves.count == 3, "main line should ignore variation branches and include pass")
    expect(moves[0].color == .black && moves[0].x == 15 && moves[0].y == 3, "B[pd] coordinate")
    expect(moves[1].color == .white && moves[1].x == 3 && moves[1].y == 3, "W[dd] coordinate")
    expect(moves[2].color == .black && moves[2].isPass, "empty B[] pass")

    let ttPass = try QixiSGFParser.parseMainLineMoves(from: "(;SZ[19];W[tt])")
    expect(ttPass.count == 1 && ttPass[0].isPass, "W[tt] pass")

    expectThrows("unsupported board size") {
      _ = try QixiSGFParser.parseMainLineMoves(from: "(;SZ[13];B[aa])")
    }

    expectThrows("invalid coordinate") {
      _ = try QixiSGFParser.parseMainLineMoves(from: "(;SZ[19];B[zz])")
    }

    let illegalKo = try QixiSGFParser.parseMainLineMoves(
      from: "(;SZ[19];B[ab];B[ba];B[cb];W[bb];W[ac];W[cc];W[bd];B[bc];W[bb])"
    )
    expect(
      QixiBoardPosition.firstIllegalMoveIndex(in: illegalKo) == 8,
      "imported SGF line should expose immediate ko recapture as illegal"
    )
    expectThrows("validated immediate ko recapture") {
      _ = try QixiSGFParser.parseValidatedMainLineMoves(
        from: "(;SZ[19];B[ab];B[ba];B[cb];W[bb];W[ac];W[cc];W[bd];B[bc];W[bb])"
      )
    }
    expectThrows("validated empty game") {
      _ = try QixiSGFParser.parseValidatedMainLineMoves(from: "(;SZ[19]KM[7.5])")
    }

    let validImportedLine = try QixiSGFParser.parseValidatedMainLineMoves(
      from: "(;SZ[19];B[pd];W[dd];B[qp];W[dp])"
    )
    expect(validImportedLine.count == 4, "validated SGF line should preserve legal moves")

    // First game only: second game moves must not leak into the main line.
    let collection = try QixiSGFParser.parseFirstGame(
      from: "(;SZ[19];B[pd];W[dd])(;SZ[19];B[aa];W[bb];B[cc])"
    )
    expect(collection.moves.count == 2, "first-game parser stops after first top-level game")
    expect(collection.moves[0].x == 15 && collection.moves[0].y == 3, "collection first move B[pd]")

    // AB/AW setup stones with a following move.
    let setupGame = try QixiSGFParser.parseValidatedGame(
      from: "(;SZ[19]AB[dd][pp]AW[pd];W[dq])"
    )
    expect(setupGame.setupStones.count == 3, "AB/AW setup stones are collected")
    expect(
      setupGame.setupStones.contains(where: { $0.color == .black && $0.x == 3 && $0.y == 3 }) &&
        setupGame.setupStones.contains(where: { $0.color == .black && $0.x == 15 && $0.y == 15 }) &&
        setupGame.setupStones.contains(where: { $0.color == .white && $0.x == 15 && $0.y == 3 }),
      "AB/AW coordinates map correctly"
    )
    expect(setupGame.moves.count == 1 && setupGame.moves[0].color == .white, "moves after setup are preserved")
    expectThrows("setup-only empty still needs stones or moves") {
      _ = try QixiSGFParser.parseValidatedGame(from: "(;SZ[19]KM[7.5])")
    }
    let setupOnly = try QixiSGFParser.parseValidatedGame(from: "(;SZ[19]AB[dd]AW[pp])")
    expect(setupOnly.moves.isEmpty && setupOnly.setupStones.count == 2, "setup-only SGF is valid")
    let plWhite = try QixiSGFParser.parseValidatedGame(from: "(;SZ[19]PL[W]AB[dd];W[pp])")
    expect(plWhite.nextPlayer == .white, "PL[W] sets White to play at root")
    let kmGame = try QixiSGFParser.parseFirstGame(from: "(;SZ[19]KM[6.5];B[pd])")
    expect(kmGame.komi == 6.5, "KM komi is parsed")

    // Export round-trip: coordinates, pass, setup stones, komi, and PL.
    // Setup at dd/pp; moves must not occupy those points.
    let exportMoves = [
      BoardMove(color: .white, x: 15, y: 3),  // W[pd]
      BoardMove(color: .black, x: 3, y: 15),  // B[dp]
      BoardMove(pass: .white)
    ]
    let exportSetup = [
      BoardSetupStone(color: .black, x: 3, y: 3),    // AB[dd]
      BoardSetupStone(color: .white, x: 15, y: 15)  // AW[pp]
    ]
    let exported = QixiSGFParser.exportGame(
      moves: exportMoves,
      setupStones: exportSetup,
      komi: 7.5,
      nextPlayer: .white
    )
    expect(exported.contains("FF[4]"), "export writes FF[4]")
    expect(exported.contains("KM[7.5]"), "export writes komi")
    // First move is white so PL is optional; empty-history PL still covered via setup-only path.
    expect(exported.contains("AB[dd]"), "export writes black setup")
    expect(exported.contains("AW[pp]"), "export writes white setup")
    expect(exported.contains(";W[pd]"), "export writes W[pd]")
    expect(exported.contains(";B[dp]"), "export writes B[dp]")
    expect(exported.contains(";W[]"), "export writes empty pass")
    let reparsed = try QixiSGFParser.parseValidatedGame(from: exported)
    expect(reparsed.moves.count == 3, "export round-trip preserves move count")
    expect(reparsed.moves[0].color == .white && reparsed.moves[0].x == 15, "export round-trip W[pd]")
    expect(reparsed.moves[2].isPass, "export round-trip pass")
    expect(reparsed.setupStones.count == 2, "export round-trip setup stones")
    expect(reparsed.komi == 7.5, "export round-trip komi")
    expect(reparsed.nextPlayer == .white, "export round-trip next player")

    let plExport = QixiSGFParser.exportGame(
      moves: [],
      setupStones: [BoardSetupStone(color: .black, x: 3, y: 3)],
      komi: 6.5,
      nextPlayer: .white
    )
    expect(plExport.contains("PL[W]"), "export writes PL when history is empty")
    let plReparsed = try QixiSGFParser.parseValidatedGame(from: plExport)
    expect(plReparsed.nextPlayer == .white && plReparsed.moves.isEmpty, "setup-only export preserves PL")

    let latin1Text = try QixiSGFParser.loadText(from: Data([0x28, 0x3B, 0x43, 0x5B, 0xE9, 0x5D, 0x3B, 0x42, 0x5B, 0x70, 0x64, 0x5D, 0x29]))
    expect(latin1Text.contains("é"), "SGF text loader accepts Latin-1 SGF comments")
    let tempSGFURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qixi-small-import.sgf")
    try Data("(;SZ[19];B[pd];W[dd])".utf8).write(to: tempSGFURL, options: [.atomic])
    defer { try? FileManager.default.removeItem(at: tempSGFURL) }
    let tempSGFText = try QixiSGFParser.loadText(from: tempSGFURL)
    expect(tempSGFText.contains("B[pd]"), "SGF URL loader reads a bounded imported file")
    expectOversizedDataRejected()
    try expectOversizedURLRejected()
    try expectSymbolicLinkURLRejected(targetURL: tempSGFURL)
    try expectDirectoryURLRejected()

    print("SGF parser smoke passed")
  }

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fputs("SGF parser smoke failed: \(message)\n", stderr)
      exit(1)
    }
  }

  static func expectThrows(_ message: String, _ body: () throws -> Void) {
    do {
      try body()
      fputs("SGF parser smoke failed: expected throw for \(message)\n", stderr)
      exit(1)
    } catch {
      return
    }
  }

  static func expectOversizedDataRejected() {
    do {
      _ = try QixiSGFParser.loadText(from: Data(count: Int(QixiSGFParser.maxInputBytes) + 1))
      fail("oversized SGF Data should be rejected before text decoding")
    } catch QixiSGFParser.ParseError.inputTooLarge(let bytes, let limit) {
      expect(
        bytes == QixiSGFParser.maxInputBytes + 1 && limit == QixiSGFParser.maxInputBytes,
        "oversized SGF Data error reports exact byte budget"
      )
    } catch {
      fail("unexpected oversized SGF Data error: \(error)")
    }
  }

  static func expectOversizedURLRejected() throws {
    let oversizedURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("qixi-oversized-import.sgf")
    FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: oversizedURL) }
    let handle = try FileHandle(forWritingTo: oversizedURL)
    try handle.truncate(atOffset: QixiSGFParser.maxInputBytes + 1)
    handle.closeFile()

    do {
      _ = try QixiSGFParser.loadText(from: oversizedURL)
      fail("oversized SGF URL should be rejected before file data is loaded")
    } catch QixiSGFParser.ParseError.inputTooLarge(let bytes, let limit) {
      expect(
        bytes == QixiSGFParser.maxInputBytes + 1 && limit == QixiSGFParser.maxInputBytes,
        "oversized SGF URL error reports exact byte budget"
      )
    } catch {
      fail("unexpected oversized SGF URL error: \(error)")
    }
  }

  static func expectSymbolicLinkURLRejected(targetURL: URL) throws {
    let linkedURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("qixi-linked-import.sgf")
    try? FileManager.default.removeItem(at: linkedURL)
    defer { try? FileManager.default.removeItem(at: linkedURL) }
    try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: targetURL)

    do {
      _ = try QixiSGFParser.loadText(from: linkedURL)
      fail("symbolic-link SGF URL should be rejected before FileHandle read")
    } catch QixiSGFParser.ParseError.symbolicLink(let path) {
      expect(path == linkedURL.path, "symbolic-link SGF URL error reports the linked path")
    } catch {
      fail("unexpected symbolic-link SGF URL error: \(error)")
    }
  }

  static func expectDirectoryURLRejected() throws {
    let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("qixi-sgf-directory", isDirectory: true)
    try? FileManager.default.removeItem(at: directoryURL)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    do {
      _ = try QixiSGFParser.loadText(from: directoryURL)
      fail("directory SGF URL should be rejected before FileHandle read")
    } catch QixiSGFParser.ParseError.notRegularFile(let path) {
      expect(path == directoryURL.path, "directory SGF URL error reports the directory path")
    } catch {
      fail("unexpected directory SGF URL error: \(error)")
    }
  }

  static func fail(_ message: String) -> Never {
    fputs("SGF parser smoke failed: \(message)\n", stderr)
    exit(1)
  }
}
