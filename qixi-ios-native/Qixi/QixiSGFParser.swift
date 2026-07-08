import Foundation

enum QixiSGFParser {
  static let maxInputBytes: UInt64 = 4 * 1024 * 1024

  enum ParseError: Error, Equatable {
    case unreadableInput
    case inputTooLarge(bytes: UInt64, limit: UInt64)
    case symbolicLink(String)
    case notRegularFile(String)
    case invalidEncoding
    case noMoves
    case unsupportedBoardSize
    case invalidCoordinate
    case illegalMove(ply: Int)
  }

  static func loadText(from url: URL) throws -> String {
    try validateImportFileURL(url)
    if let byteCount = try fileByteCount(at: url) {
      try validateInputByteCount(byteCount)
    }
    return try loadText(from: boundedData(from: url))
  }

  static func loadText(from data: Data) throws -> String {
    try validateInputByteCount(UInt64(data.count))
    guard let text = String(data: data, encoding: .utf8) ??
      String(data: data, encoding: .isoLatin1) else {
      throw ParseError.invalidEncoding
    }
    return text
  }

  static func parseMainLineMoves(from text: String) throws -> [BoardMove] {
    let scalars = text.unicodeScalars
    var depth = 0
    var index = scalars.startIndex
    var moves: [BoardMove] = []
    var boardSize = 19

    while index < scalars.endIndex {
      let scalar = scalars[index]
      if scalar == "(" {
        depth += 1
        scalars.formIndex(after: &index)
      } else if scalar == ")" {
        depth = max(0, depth - 1)
        scalars.formIndex(after: &index)
      } else if depth == 1 && scalar == ";" {
        scalars.formIndex(after: &index)
        while index < scalars.endIndex {
          if scalars[index] == ";" || scalars[index] == "(" || scalars[index] == ")" { break }
          guard isPropertyIdentifierStart(scalars[index]) else {
            scalars.formIndex(after: &index)
            continue
          }
          let propertyStart = index
          while index < scalars.endIndex, isPropertyIdentifierPart(scalars[index]) {
            scalars.formIndex(after: &index)
          }
          let property = String(scalars[propertyStart..<index])
          let values = readPropertyValues(scalars, index: &index)
          if property == "SZ", let value = values.first, let parsed = Int(value), parsed != 19 {
            throw ParseError.unsupportedBoardSize
          }
          if property == "SZ", let value = values.first, let parsed = Int(value) {
            boardSize = parsed
          }
          if property == "B" || property == "W", let value = values.first {
            let color: StoneColor = property == "B" ? .black : .white
            moves.append(try move(color: color, value: value, boardSize: boardSize))
          }
        }
      } else {
        scalars.formIndex(after: &index)
      }
    }
    return moves
  }

  static func parseValidatedMainLineMoves(from text: String) throws -> [BoardMove] {
    let moves = try parseMainLineMoves(from: text)
    guard !moves.isEmpty else { throw ParseError.noMoves }
    if let illegalIndex = QixiBoardPosition.firstIllegalMoveIndex(in: moves) {
      throw ParseError.illegalMove(ply: illegalIndex + 1)
    }
    return moves
  }

  private static func move(color: StoneColor, value: String, boardSize: Int) throws -> BoardMove {
    if value.isEmpty || value == "tt" {
      return BoardMove(pass: color)
    }
    let lower = value.lowercased()
    guard lower.count == 2,
          let xScalar = lower.unicodeScalars.first,
          let yScalar = lower.unicodeScalars.dropFirst().first else {
      throw ParseError.invalidCoordinate
    }
    let a = UnicodeScalar("a").value
    let x = Int(xScalar.value - a)
    let y = Int(yScalar.value - a)
    guard x >= 0, x < boardSize, y >= 0, y < boardSize else {
      throw ParseError.invalidCoordinate
    }
    return BoardMove(color: color, x: x, y: y)
  }

  private static func readPropertyValues(
    _ scalars: String.UnicodeScalarView,
    index: inout String.UnicodeScalarView.Index
  ) -> [String] {
    var values: [String] = []
    while index < scalars.endIndex, scalars[index] == "[" {
      scalars.formIndex(after: &index)
      var valueScalars: [UnicodeScalar] = []
      while index < scalars.endIndex {
        let scalar = scalars[index]
        if scalar == "\\" {
          let next = scalars.index(after: index)
          if next < scalars.endIndex {
            valueScalars.append(scalars[next])
            index = scalars.index(after: next)
          } else {
            index = next
          }
        } else if scalar == "]" {
          scalars.formIndex(after: &index)
          break
        } else {
          valueScalars.append(scalar)
          scalars.formIndex(after: &index)
        }
      }
      values.append(String(String.UnicodeScalarView(valueScalars)))
    }
    return values
  }

  private static func isPropertyIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
    scalar.value >= UnicodeScalar("A").value && scalar.value <= UnicodeScalar("Z").value
  }

  private static func isPropertyIdentifierPart(_ scalar: UnicodeScalar) -> Bool {
    isPropertyIdentifierStart(scalar)
  }

  private static func validateInputByteCount(_ byteCount: UInt64) throws {
    guard byteCount <= maxInputBytes else {
      throw ParseError.inputTooLarge(bytes: byteCount, limit: maxInputBytes)
    }
  }

  private static func validateImportFileURL(_ url: URL) throws {
    try rejectSymbolicLinkComponents(in: url)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    } catch {
      throw ParseError.unreadableInput
    }
    guard values.isSymbolicLink != true else {
      throw ParseError.symbolicLink(url.path)
    }
    guard values.isRegularFile == true && values.isDirectory != true else {
      throw ParseError.notRegularFile(url.path)
    }
  }

  private static func rejectSymbolicLinkComponents(in url: URL) throws {
    let components = url.standardizedFileURL.pathComponents
    guard !components.isEmpty else { return }
    var currentPath = components[0]
    for component in components.dropFirst() {
      currentPath = (currentPath as NSString).appendingPathComponent(component)
      let currentURL = URL(fileURLWithPath: currentPath)
      let values = try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true,
         !isAllowedPlatformSymlinkAlias(currentURL) {
        throw ParseError.symbolicLink(currentURL.path)
      }
    }
  }

  private static func isAllowedPlatformSymlinkAlias(_ url: URL) -> Bool {
    #if os(macOS) || os(iOS)
    let allowedAliases = [
      "/var": "private/var",
      "/tmp": "private/tmp",
      "/etc": "private/etc"
    ]
    guard let expectedTarget = allowedAliases[url.path] else { return false }
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
      return false
    }
    return target == expectedTarget || target == "/\(expectedTarget)"
    #else
    return false
    #endif
  }

  private static func boundedData(from url: URL) throws -> Data {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw ParseError.unreadableInput
    }
    defer {
      try? handle.close()
    }
    let readLimit = Int(maxInputBytes) + 1
    let data = handle.readData(ofLength: readLimit)
    try validateInputByteCount(UInt64(data.count))
    return data
  }

  private static func fileByteCount(at url: URL) throws -> UInt64? {
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      if let fileSize = values.fileSize {
        return UInt64(max(0, fileSize))
      }
    } catch {
      throw ParseError.unreadableInput
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      if let size = attributes[.size] as? NSNumber {
        return size.uint64Value
      }
    } catch {
      throw ParseError.unreadableInput
    }
    return nil
  }
}
