import CoreGraphics
import Foundation
import ImageIO

struct RecognizedBoardStone: Identifiable, Equatable {
  var id: Int { y * 19 + x }
  var x: Int
  var y: Int
  var color: StoneColor
  var confidence: Double
}

struct QixiBoardRecognitionResult: Equatable {
  var stones: [RecognizedBoardStone]
  var gridX: [Double]
  var gridY: [Double]
}

struct QixiBoardImageSelection: Equatable {
  var topLeft: CGPoint
  var topRight: CGPoint
  var bottomRight: CGPoint
  var bottomLeft: CGPoint

  static let defaultGrid = QixiBoardImageSelection(
    topLeft: CGPoint(x: 0.35, y: 0.16),
    topRight: CGPoint(x: 0.97, y: 0.08),
    bottomRight: CGPoint(x: 0.94, y: 0.38),
    bottomLeft: CGPoint(x: 0.47, y: 0.43)
  )

  func clamped() -> QixiBoardImageSelection {
    QixiBoardImageSelection(
      topLeft: Self.clampedPoint(topLeft),
      topRight: Self.clampedPoint(topRight),
      bottomRight: Self.clampedPoint(bottomRight),
      bottomLeft: Self.clampedPoint(bottomLeft)
    )
  }

  private static func clampedPoint(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: min(1.0, max(0.0, point.x)),
      y: min(1.0, max(0.0, point.y))
    )
  }
}

enum QixiBoardImageRecognizer {
  static let maxInputImageBytes: UInt64 = 32 * 1024 * 1024
  private static let maximumDecodePixelSize = 1600
  private static let maximumLocatorPixelSize = 700

  private enum StoneClassificationMode {
    case automatic
    case selectedPhoto
  }

  enum RecognitionError: Error, Equatable, LocalizedError {
    case unreadableImage
    case imageTooLarge(bytes: UInt64, limit: UInt64)
    case symbolicLink(String)
    case notRegularFile(String)
    case gridNotFound

    var errorDescription: String? {
      switch self {
      case .unreadableImage:
        return "image could not be decoded"
      case .imageTooLarge(let bytes, let limit):
        return "image has \(bytes) bytes, exceeding \(limit)"
      case .symbolicLink(let path):
        return "image path is a symbolic link: \(path)"
      case .notRegularFile(let path):
        return "image path is not a regular file: \(path)"
      case .gridNotFound:
        return "board grid was not found"
      }
    }
  }

  static func recognizeBoard(from data: Data) throws -> QixiBoardRecognitionResult {
    try validateInputImageByteCount(UInt64(data.count))
    return try recognizeBoard(from: decodedImage(from: data))
  }

  static func recognizeBoard(
    from data: Data,
    selection: QixiBoardImageSelection
  ) throws -> QixiBoardRecognitionResult {
    try validateInputImageByteCount(UInt64(data.count))
    return try recognizeBoard(from: decodedImage(from: data), selection: selection)
  }

  static func suggestedSelection(from data: Data) throws -> QixiBoardImageSelection {
    try validateInputImageByteCount(UInt64(data.count))
    return try suggestedSelection(from: decodedImage(from: data))
  }

  static func validatePendingSelectionImageDataForUI(_ data: Data) throws {
    try validateInputImageByteCount(UInt64(data.count))
    _ = try decodedImage(from: data)
  }

  private static func decodedImage(from data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0 else {
      throw RecognitionError.unreadableImage
    }
    return try thumbnailImage(from: source, allowFullImageFallback: true)
  }

  private static func decodedImage(from url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else {
      throw RecognitionError.unreadableImage
    }
    return try thumbnailImage(from: source, allowFullImageFallback: false)
  }

  private static func thumbnailImage(
    from source: CGImageSource,
    allowFullImageFallback: Bool
  ) throws -> CGImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumDecodePixelSize
    ]
    if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
      return image
    }
    guard allowFullImageFallback else {
      throw RecognitionError.unreadableImage
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw RecognitionError.unreadableImage
    }
    return image
  }

  static func recognizeBoard(from url: URL) throws -> QixiBoardRecognitionResult {
    try validateImportFileURL(url)
    if let byteCount = try compressedFileByteCount(at: url) {
      try validateInputImageByteCount(byteCount)
    }
    return try recognizeBoard(from: decodedImage(from: url))
  }

  static func recognizeBoard(
    from url: URL,
    selection: QixiBoardImageSelection
  ) throws -> QixiBoardRecognitionResult {
    try validateImportFileURL(url)
    if let byteCount = try compressedFileByteCount(at: url) {
      try validateInputImageByteCount(byteCount)
    }
    return try recognizeBoard(from: decodedImage(from: url), selection: selection)
  }

  private static func validateImportFileURL(_ url: URL) throws {
    try rejectSymbolicLinkComponents(in: url)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    } catch {
      throw RecognitionError.unreadableImage
    }
    guard values.isSymbolicLink != true else {
      throw RecognitionError.symbolicLink(url.path)
    }
    guard values.isRegularFile == true && values.isDirectory != true else {
      throw RecognitionError.notRegularFile(url.path)
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
        throw RecognitionError.symbolicLink(currentURL.path)
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

  private static func validateInputImageByteCount(_ byteCount: UInt64) throws {
    guard byteCount <= maxInputImageBytes else {
      throw RecognitionError.imageTooLarge(bytes: byteCount, limit: maxInputImageBytes)
    }
  }

  private static func compressedFileByteCount(at url: URL) throws -> UInt64? {
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      if let fileSize = values.fileSize {
        return UInt64(max(0, fileSize))
      }
    } catch {
      throw RecognitionError.unreadableImage
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      if let size = attributes[.size] as? NSNumber {
        return size.uint64Value
      }
    } catch {
      throw RecognitionError.unreadableImage
    }
    return nil
  }

  static func recognizeBoard(from image: CGImage) throws -> QixiBoardRecognitionResult {
    try recognizeBoard(from: image, selection: nil)
  }

  static func recognizeBoard(
    from image: CGImage,
    selection: QixiBoardImageSelection?
  ) throws -> QixiBoardRecognitionResult {
    if let selection {
      return try recognizeSelectedBoard(from: image, selection: selection)
    }
    for degrees in [0.0, -2.0, 2.0, -1.0, 1.0, -3.0, 3.0] {
      let candidate = degrees == 0.0 ? image : try rotatedImage(image, degrees: degrees)
      if let result = try? recognizeAxisAlignedBoard(from: candidate) {
        return result
      }
    }
    if let rectified = try? perspectiveRectifiedImage(image) {
      if let result = try? recognizeAxisAlignedBoard(from: rectified) {
        return result
      }
      if let result = try? recognizeFixedGridBoard(from: rectified) {
        return result
      }
    }
    return try recognizeFixedGridBoard(from: image)
  }

  static func suggestedSelection(from image: CGImage) throws -> QixiBoardImageSelection {
    let locatorImage = try downscaledImageForBoardLocator(image)
    let raster = try Raster(image: locatorImage)
    guard let quad = estimateGridSearchBoardQuad(in: raster) ??
      estimateWarmBoardQuad(in: raster) ??
      estimateBoardQuad(in: raster) else {
      return .defaultGrid
    }
    return QixiBoardImageSelection(
      topLeft: CGPoint(x: quad.topLeft.x / Double(raster.width), y: quad.topLeft.y / Double(raster.height)),
      topRight: CGPoint(x: quad.topRight.x / Double(raster.width), y: quad.topRight.y / Double(raster.height)),
      bottomRight: CGPoint(x: quad.bottomRight.x / Double(raster.width), y: quad.bottomRight.y / Double(raster.height)),
      bottomLeft: CGPoint(x: quad.bottomLeft.x / Double(raster.width), y: quad.bottomLeft.y / Double(raster.height))
    ).clamped()
  }

  private static func downscaledImageForBoardLocator(_ image: CGImage) throws -> CGImage {
    let longestSide = max(image.width, image.height)
    guard longestSide > maximumLocatorPixelSize else { return image }
    let scale = Double(maximumLocatorPixelSize) / Double(longestSide)
    let width = max(1, Int(round(Double(image.width) * scale)))
    let height = max(1, Int(round(Double(image.height) * scale)))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw RecognitionError.unreadableImage
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let output = context.makeImage() else {
      throw RecognitionError.unreadableImage
    }
    return output
  }

  private static func recognizeSelectedBoard(
    from image: CGImage,
    selection: QixiBoardImageSelection
  ) throws -> QixiBoardRecognitionResult {
    let quad = boardQuad(from: selection, width: image.width, height: image.height)
    guard quadrilateralArea(quad) >= Double(image.width * image.height) * 0.04 else {
      throw RecognitionError.gridNotFound
    }
    let rectified = try perspectiveRectifiedImage(image, quad: quad)
    return try recognizeFixedGridBoard(from: rectified, classificationMode: .selectedPhoto)
  }

  private static func recognizeAxisAlignedBoard(from image: CGImage) throws -> QixiBoardRecognitionResult {
    let raster = try Raster(image: image)
    let vertical = detectLines(in: verticalDarkProjection(raster))
    let horizontal = detectLines(in: horizontalDarkProjection(raster))
    guard isUsableAxisAlignedGrid(vertical, crossExtent: raster.height),
          isUsableAxisAlignedGrid(horizontal, crossExtent: raster.width) else {
      throw RecognitionError.gridNotFound
    }

    let stepX = medianGap(vertical.centers)
    let stepY = medianGap(horizontal.centers)
    let radius = max(3.0, min(stepX, stepY) * 0.32)
    var stones: [RecognizedBoardStone] = []
    for y in 0..<19 {
      for x in 0..<19 {
        let sample = sampleIntersection(
          raster,
          centerX: vertical.centers[x],
          centerY: horizontal.centers[y],
          radius: radius
        )
        if let stone = classifiedStone(x: x, y: y, sample: sample) {
          stones.append(stone)
        }
      }
    }

    return QixiBoardRecognitionResult(stones: stones, gridX: vertical.centers, gridY: horizontal.centers)
  }

  private static func recognizeFixedGridBoard(
    from image: CGImage,
    classificationMode: StoneClassificationMode = .automatic
  ) throws -> QixiBoardRecognitionResult {
    if classificationMode == .selectedPhoto {
      return try recognizeFixedGridBoardWithImagoClustering(from: image)
    }

    let raster = try Raster(image: image)
    let side = Double(min(raster.width, raster.height))
    guard side >= 120 else { throw RecognitionError.gridNotFound }
    let originX = (Double(raster.width) - side) / 2.0
    let originY = (Double(raster.height) - side) / 2.0
    let pad = side * (60.0 / 960.0)
    let step = side * ((840.0 / 18.0) / 960.0)
    let gridX = (0..<19).map { originX + pad + Double($0) * step }
    let gridY = (0..<19).map { originY + pad + Double($0) * step }
    let radiusScale = classificationMode == .selectedPhoto ? 0.36 : 0.38
    let radius = max(3.0, step * radiusScale)
    var stones: [RecognizedBoardStone] = []
    stones.reserveCapacity(80)
    for y in 0..<19 {
      for x in 0..<19 {
        let sample = sampleIntersection(
          raster,
          centerX: gridX[x],
          centerY: gridY[y],
          radius: radius
        )
        if let stone = classifiedStone(x: x, y: y, sample: sample, mode: classificationMode) {
          stones.append(stone)
        }
      }
    }
    return QixiBoardRecognitionResult(stones: stones, gridX: gridX, gridY: gridY)
  }

  private struct ImagoSample {
    var x: Int
    var y: Int
    var lightness: Double
    var saturation: Double
  }

  private static func recognizeFixedGridBoardWithImagoClustering(
    from image: CGImage
  ) throws -> QixiBoardRecognitionResult {
    let raster = try Raster(image: image)
    let side = Double(min(raster.width, raster.height))
    guard side >= 120 else { throw RecognitionError.gridNotFound }
    let originX = (Double(raster.width) - side) / 2.0
    let originY = (Double(raster.height) - side) / 2.0
    let pad = side * (60.0 / 960.0)
    let step = side * ((840.0 / 18.0) / 960.0)
    let gridX = (0..<19).map { originX + pad + Double($0) * step }
    let gridY = (0..<19).map { originY + pad + Double($0) * step }

    // Port of tomasmcz/imago's intersection classifier:
    // sample RGB around each grid point, convert average RGB to HLS
    // (lightness, saturation), then run 3-means for black / empty / white.
    var samples: [ImagoSample] = []
    samples.reserveCapacity(361)
    let radius = max(3.0, step * 0.18)
    for y in 0..<19 {
      for x in 0..<19 {
        let feature = imagoStoneFeature(
          raster,
          centerX: gridX[x],
          centerY: gridY[y],
          radius: radius
        )
        samples.append(ImagoSample(x: x, y: y, lightness: feature.lightness, saturation: feature.saturation))
      }
    }

    let labels = imagoClusterLabels(samples)
    guard labels.count == samples.count else {
      throw RecognitionError.gridNotFound
    }
    let centers = imagoClusterCenters(samples, labels: labels)
    let orderedClusters = centers.indices.sorted { lhs, rhs in
      centers[lhs].lightness < centers[rhs].lightness
    }
    guard orderedClusters.count == 3 else { throw RecognitionError.gridNotFound }
    let blackCluster = orderedClusters[0]
    let whiteCluster = orderedClusters[2]

    var stones: [RecognizedBoardStone] = []
    stones.reserveCapacity(80)
    for (index, sample) in samples.enumerated() {
      let label = labels[index]
      let localSample = sampleIntersection(
        raster,
        centerX: gridX[sample.x],
        centerY: gridY[sample.y],
        radius: max(3.0, step * 0.30)
      )
      if label == blackCluster {
        if let stone = classifiedStone(x: sample.x, y: sample.y, sample: localSample, mode: .selectedPhoto),
           stone.color == .black {
          stones.append(stone)
        }
      } else if label == whiteCluster {
        if let stone = classifiedStone(x: sample.x, y: sample.y, sample: localSample, mode: .selectedPhoto),
           stone.color == .white {
          stones.append(stone)
        }
      }
    }

    return QixiBoardRecognitionResult(stones: stones, gridX: gridX, gridY: gridY)
  }

  private static func imagoStoneFeature(
    _ raster: Raster,
    centerX: Double,
    centerY: Double,
    radius: Double
  ) -> (lightness: Double, saturation: Double) {
    let minX = max(0, Int(floor(centerX - radius)))
    let maxX = min(raster.width - 1, Int(ceil(centerX + radius)))
    let minY = max(0, Int(floor(centerY - radius)))
    let maxY = min(raster.height - 1, Int(ceil(centerY + radius)))
    let radiusSquared = radius * radius
    var count = 0.0
    var redTotal = 0.0
    var greenTotal = 0.0
    var blueTotal = 0.0
    for y in minY...maxY {
      for x in minX...maxX {
        let dx = Double(x) - centerX
        let dy = Double(y) - centerY
        guard dx * dx + dy * dy <= radiusSquared else { continue }
        let color = raster.rgb(x: x, y: y)
        redTotal += color.red
        greenTotal += color.green
        blueTotal += color.blue
        count += 1.0
      }
    }
    guard count > 0 else { return (0.0, 0.0) }
    return hlsLightnessAndSaturation(
      red: redTotal / (count * 255.0),
      green: greenTotal / (count * 255.0),
      blue: blueTotal / (count * 255.0)
    )
  }

  private static func hlsLightnessAndSaturation(
    red: Double,
    green: Double,
    blue: Double
  ) -> (lightness: Double, saturation: Double) {
    let maximum = max(red, max(green, blue))
    let minimum = min(red, min(green, blue))
    let lightness = (maximum + minimum) / 2.0
    guard maximum > minimum else {
      return (lightness, 0.0)
    }
    let delta = maximum - minimum
    let saturation: Double
    if lightness <= 0.5 {
      saturation = delta / (maximum + minimum)
    } else {
      saturation = delta / (2.0 - maximum - minimum)
    }
    return (lightness, saturation)
  }

  private static func imagoClusterLabels(_ samples: [ImagoSample]) -> [Int] {
    guard samples.count == 361 else { return [] }
    let sortedLightness = samples.map(\.lightness).sorted()
    let medianLightness = sortedLightness[sortedLightness.count / 2]
    let sortedSaturation = samples.map(\.saturation).sorted()
    let medianSaturation = sortedSaturation[sortedSaturation.count / 2]
    let blackSeed = samples.min { lhs, rhs in lhs.lightness < rhs.lightness } ?? samples[0]
    let whiteSeed = samples.max { lhs, rhs in
      lhs.lightness - 0.45 * lhs.saturation < rhs.lightness - 0.45 * rhs.saturation
    } ?? samples[0]
    var centers = [
      (lightness: blackSeed.lightness, saturation: blackSeed.saturation),
      (lightness: medianLightness, saturation: medianSaturation),
      (lightness: whiteSeed.lightness, saturation: whiteSeed.saturation)
    ]
    var labels = [Int](repeating: 1, count: samples.count)
    for _ in 0..<80 {
      var changed = false
      for (index, sample) in samples.enumerated() {
        let nearest = centers.indices.min { lhs, rhs in
          imagoDistance(sample, centers[lhs]) < imagoDistance(sample, centers[rhs])
        } ?? 1
        if labels[index] != nearest {
          labels[index] = nearest
          changed = true
        }
      }
      let newCenters = imagoClusterCenters(samples, labels: labels)
      let delta = zip(centers, newCenters).reduce(0.0) { partial, pair in
        partial + abs(pair.0.lightness - pair.1.lightness) + abs(pair.0.saturation - pair.1.saturation)
      }
      centers = newCenters
      if !changed || delta < 1.0e-6 { break }
    }
    return labels
  }

  private static func imagoClusterCenters(
    _ samples: [ImagoSample],
    labels: [Int]
  ) -> [(lightness: Double, saturation: Double)] {
    var totals = Array<(count: Double, lightness: Double, saturation: Double)>(
      repeating: (count: 0.0, lightness: 0.0, saturation: 0.0),
      count: 3
    )
    for (sample, label) in zip(samples, labels) where label >= 0 && label < totals.count {
      totals[label].count += 1.0
      totals[label].lightness += sample.lightness
      totals[label].saturation += sample.saturation
    }
    return totals.map { total in
      guard total.count > 0 else { return (0.0, 0.0) }
      return (total.lightness / total.count, total.saturation / total.count)
    }
  }

  private static func imagoDistance(
    _ sample: ImagoSample,
    _ center: (lightness: Double, saturation: Double)
  ) -> Double {
    let lightnessDelta = sample.lightness - center.lightness
    let saturationDelta = sample.saturation - center.saturation
    return sqrt(lightnessDelta * lightnessDelta + saturationDelta * saturationDelta)
  }

  private static func classifiedStone(
    x: Int,
    y: Int,
    sample: (
      meanLuma: Double,
      darkFraction: Double,
      brightFraction: Double,
      lumaStdDev: Double,
      centerMeanLuma: Double,
      outerMeanLuma: Double,
      neutralBrightFraction: Double,
      meanSaturation: Double,
      outerMeanSaturation: Double
    ),
    mode: StoneClassificationMode = .automatic
  ) -> RecognizedBoardStone? {
    let standardBlack = sample.meanLuma < 112.0 && sample.darkFraction > 0.28
    let photoBlackContrast = sample.outerMeanLuma - sample.meanLuma
    let photoBlackScore = photoBlackContrast + 40.0 * sample.darkFraction
    let photographedBlack = sample.meanLuma < 125.0 &&
      sample.darkFraction > 0.45 &&
      sample.meanSaturation < 0.50 &&
      photoBlackContrast > 6.0 &&
      photoBlackScore > 25.0
    let photographedBlackWithPhotoGrid = sample.meanLuma < 155.0 &&
      sample.darkFraction > 0.12 &&
      sample.meanSaturation < 0.72 &&
      photoBlackContrast > 0.5 &&
      photoBlackScore > 6.0
    if (mode == .automatic && standardBlack) ||
      (mode == .selectedPhoto && (photographedBlack || photographedBlackWithPhotoGrid)) {
      return RecognizedBoardStone(
        x: x,
        y: y,
        color: .black,
        confidence: min(1.0, max(0.0, (128.0 - sample.meanLuma) / 94.0))
      )
    }

    let standardWhite = sample.meanLuma > 148.0 &&
      sample.darkFraction < 0.22 &&
      sample.brightFraction > 0.42 &&
      sample.centerMeanLuma + 4.0 >= sample.outerMeanLuma
    let photoWhiteScore = (sample.meanLuma - sample.outerMeanLuma) +
      70.0 * sample.neutralBrightFraction +
      20.0 * (sample.outerMeanSaturation - sample.meanSaturation)
    let photographedWhite = sample.meanLuma > 108.0 &&
      sample.darkFraction < 0.18 &&
      sample.neutralBrightFraction > 0.30 &&
      sample.meanSaturation < 0.43 &&
      photoWhiteScore > 26.0
    let photographedWhiteWithPhotoGrid = sample.meanLuma > 92.0 &&
      sample.darkFraction < 0.34 &&
      sample.neutralBrightFraction > 0.10 &&
      sample.meanSaturation < 0.72 &&
      photoWhiteScore > 8.0
    if (mode == .automatic && standardWhite) ||
      (mode == .selectedPhoto && (photographedWhite || photographedWhiteWithPhotoGrid)) {
      return RecognizedBoardStone(
        x: x,
        y: y,
        color: .white,
        confidence: min(1.0, max(0.0, (sample.neutralBrightFraction - 0.12) / 0.62))
      )
    }

    return nil
  }

  private static func rotatedImage(_ image: CGImage, degrees: Double) throws -> CGImage {
    let radians = degrees * .pi / 180.0
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let rotatedRect = CGRect(x: 0, y: 0, width: width, height: height)
      .applying(CGAffineTransform(rotationAngle: radians))
    let outputSize = CGSize(width: ceil(abs(rotatedRect.width)), height: ceil(abs(rotatedRect.height)))
    guard let context = CGContext(
      data: nil,
      width: Int(outputSize.width),
      height: Int(outputSize.height),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw RecognitionError.unreadableImage
    }
    context.setFillColor(red: 238.0 / 255.0, green: 232.0 / 255.0, blue: 220.0 / 255.0, alpha: 1.0)
    context.fill(CGRect(origin: .zero, size: outputSize))
    context.translateBy(x: outputSize.width / 2.0, y: outputSize.height / 2.0)
    context.rotate(by: CGFloat(radians))
    context.draw(image, in: CGRect(x: -width / 2.0, y: -height / 2.0, width: width, height: height))
    guard let output = context.makeImage() else {
      throw RecognitionError.unreadableImage
    }
    return output
  }

  private struct BoardQuad {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
  }

  private static func perspectiveRectifiedImage(_ image: CGImage) throws -> CGImage {
    let raster = try Raster(image: image)
    guard let quad = estimateBoardQuad(in: raster) else {
      throw RecognitionError.gridNotFound
    }
    return try perspectiveRectifiedImage(image, quad: quad)
  }

  private static func perspectiveRectifiedImage(_ image: CGImage, quad: BoardQuad) throws -> CGImage {
    let raster = try Raster(image: image)
    let side = max(720, min(1400, max(raster.width, raster.height)))
    let pad = Double(side) * (60.0 / 960.0)
    let gridMin = pad
    let gridMax = Double(side) - pad
    let gridSpan = gridMax - gridMin
    let projection = ProjectiveQuadMapping(quad: quad)
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    for y in 0..<side {
      for x in 0..<side {
        let offset = (y * side + x) * 4
        let u = (Double(x) - gridMin) / gridSpan
        let v = (Double(y) - gridMin) / gridSpan
        let sourcePoint = projection.point(u: u, v: v)
        let color = raster.sampleRGBA(x: sourcePoint.x, y: sourcePoint.y)
        pixels[offset] = color.red
        pixels[offset + 1] = color.green
        pixels[offset + 2] = color.blue
        pixels[offset + 3] = 255
      }
    }

    guard let context = CGContext(
      data: &pixels,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let output = context.makeImage() else {
      throw RecognitionError.unreadableImage
    }
    return output
  }

  private static func boardQuad(from selection: QixiBoardImageSelection, width: Int, height: Int) -> BoardQuad {
    let clamped = selection.clamped()
    let w = Double(width - 1)
    let h = Double(height - 1)
    return BoardQuad(
      topLeft: CGPoint(x: clamped.topLeft.x * w, y: clamped.topLeft.y * h),
      topRight: CGPoint(x: clamped.topRight.x * w, y: clamped.topRight.y * h),
      bottomRight: CGPoint(x: clamped.bottomRight.x * w, y: clamped.bottomRight.y * h),
      bottomLeft: CGPoint(x: clamped.bottomLeft.x * w, y: clamped.bottomLeft.y * h)
    )
  }

  private struct LocatorFields {
    var width: Int
    var height: Int
    var luma: [Double]
    var tanScore: [Double]
    var gradient: [Double]
    var strictBoardMask: [Bool]
  }

  private struct ColorComponent {
    var count: Int
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
  }

  private struct LocatorBounds {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
  }

  private typealias LocatorPreset = (
    leftInset: Double,
    topLeftInset: Double,
    rightInset: Double,
    topRightInset: Double,
    bottomRightInset: Double,
    bottomInset: Double,
    bottomLeftInset: Double,
    bottomLeftBottomInset: Double
  )

  private struct ProjectiveQuadMapping {
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var e: Double
    var f: Double
    var g: Double
    var h: Double

    init(quad: BoardQuad) {
      let tl = quad.topLeft
      let tr = quad.topRight
      let br = quad.bottomRight
      let bl = quad.bottomLeft
      let dx1 = tr.x - br.x
      let dx2 = bl.x - br.x
      let dx3 = tl.x - tr.x + br.x - bl.x
      let dy1 = tr.y - br.y
      let dy2 = bl.y - br.y
      let dy3 = tl.y - tr.y + br.y - bl.y
      let denominator = dx1 * dy2 - dx2 * dy1
      if abs(denominator) < 1.0e-9 {
        g = 0.0
        h = 0.0
      } else {
        g = (dx3 * dy2 - dx2 * dy3) / denominator
        h = (dx1 * dy3 - dx3 * dy1) / denominator
      }
      a = tr.x - tl.x + g * tr.x
      b = bl.x - tl.x + h * bl.x
      c = tl.x
      d = tr.y - tl.y + g * tr.y
      e = bl.y - tl.y + h * bl.y
      f = tl.y
    }

    func point(u: Double, v: Double) -> CGPoint {
      let denominator = g * u + h * v + 1.0
      guard abs(denominator) > 1.0e-9 else {
        return CGPoint(x: c, y: f)
      }
      return CGPoint(
        x: (a * u + b * v + c) / denominator,
        y: (d * u + e * v + f) / denominator
      )
    }
  }

  private static func estimateGridSearchBoardQuad(in raster: Raster) -> BoardQuad? {
    let fields = makeLocatorFields(from: raster)
    let components = boardColorComponents(
      mask: fields.strictBoardMask,
      width: fields.width,
      height: fields.height
    )
    guard let boardComponent = mergedBoardColorComponent(from: components) else {
      return nil
    }
    guard boardComponent.width > max(80, fields.width / 5),
          boardComponent.height > max(70, fields.height / 7) else {
      return nil
    }

    let width = Double(fields.width)
    let height = Double(fields.height)
    let minX = Double(boardComponent.minX)
    let minY = Double(boardComponent.minY)
    let maxX = Double(boardComponent.maxX)
    let maxY = Double(boardComponent.maxY)
    let boardWidth = max(1.0, maxX - minX)
    let boardHeight = max(1.0, maxY - minY)
    let leftBoundInset = (minX / width) > 0.35 ? -0.02 : 0.05
    let bounds = LocatorBounds(
      minX: max(0.0, minX + leftBoundInset * boardWidth),
      minY: max(0.0, minY - 0.10 * boardHeight),
      maxX: min(width - 1.0, maxX + 0.08 * boardWidth),
      maxY: min(height - 1.0, maxY + 0.18 * boardHeight)
    )
    let presets: [LocatorPreset] = [
      (0.06, 0.24, 0.01, 0.05, 0.04, 0.04, 0.20, 0.02),
      (0.08, 0.34, 0.01, 0.12, 0.04, 0.04, 0.24, 0.02),
      (0.12, 0.23, 0.02, 0.12, 0.04, 0.04, 0.20, 0.02),
      (0.05, 0.08, 0.01, 0.02, 0.04, 0.03, 0.13, 0.02),
      (0.12, 0.34, 0.01, 0.06, 0.03, 0.02, 0.24, 0.01)
    ]

    var bestQuad: BoardQuad?
    var bestScore = -Double.infinity
    for preset in presets {
      let initial = BoardQuad(
        topLeft: CGPoint(
          x: minX + preset.leftInset * boardWidth,
          y: minY + preset.topLeftInset * boardHeight
        ),
        topRight: CGPoint(
          x: maxX - preset.rightInset * boardWidth,
          y: minY + preset.topRightInset * boardHeight
        ),
        bottomRight: CGPoint(
          x: maxX - preset.bottomRightInset * boardWidth,
          y: maxY - preset.bottomInset * boardHeight
        ),
        bottomLeft: CGPoint(
          x: minX + preset.bottomLeftInset * boardWidth,
          y: maxY - preset.bottomLeftBottomInset * boardHeight
        )
      )
      let refined = refinedGridSearchQuad(
        initial,
        fields: fields,
        bounds: bounds
      )
      if refined.score > bestScore {
        bestScore = refined.score
        bestQuad = refined.quad
      }
    }

    guard let bestQuad, bestScore > 0.20 else {
      return nil
    }
    var finalQuad = regularizedLocatorQuad(bestQuad, fields: fields)
    if minX / width > 0.35 {
      finalQuad.topLeft.x = min(finalQuad.topLeft.x, minX + 0.08 * boardWidth)
      finalQuad.topLeft.y = min(finalQuad.topLeft.y, minY + 0.16 * boardHeight)
      finalQuad.topRight.y = min(finalQuad.topRight.y, minY + 0.14 * boardHeight)
      finalQuad.bottomLeft.x = min(finalQuad.bottomLeft.x, minX + 0.20 * boardWidth)
      finalQuad.bottomLeft.y = min(finalQuad.bottomLeft.y, minY + 0.88 * boardHeight)
    }
    return finalQuad
  }

  private static func makeLocatorFields(from raster: Raster) -> LocatorFields {
    let width = raster.width
    let height = raster.height
    var luma = [Double](repeating: 0.0, count: width * height)
    var tanScore = [Double](repeating: 0.0, count: width * height)
    var strictMask = [Bool](repeating: false, count: width * height)

    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let red = Double(raster.pixels[offset])
        let green = Double(raster.pixels[offset + 1])
        let blue = Double(raster.pixels[offset + 2])
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        let saturation = maxChannel <= 0.0 ? 0.0 : (maxChannel - minChannel) / maxChannel
        let pixelLuma = red * 0.299 + green * 0.587 + blue * 0.114
        let index = y * width + x
        luma[index] = pixelLuma
        tanScore[index] =
          clamp((red - blue - 5.0) / 100.0, lower: 0.0, upper: 1.0) *
          clamp((green - blue) / 80.0, lower: 0.0, upper: 1.0) *
          clamp((215.0 - pixelLuma) / 95.0, lower: 0.0, upper: 1.0) *
          clamp((pixelLuma - 45.0) / 90.0, lower: 0.0, upper: 1.0)
        strictMask[index] =
          red > 75.0 &&
          green > 55.0 &&
          blue > 25.0 &&
          red > green * 1.03 &&
          green > blue * 1.18 &&
          red > blue * 1.45 &&
          red - green > 5.0 &&
          red - green < 80.0 &&
          green - blue > 12.0 &&
          green - blue < 95.0 &&
          saturation > 0.20 &&
          pixelLuma > 70.0 &&
          pixelLuma < 180.0
      }
    }

    var gradient = [Double](repeating: 0.0, count: width * height)
    guard width >= 3, height >= 3 else {
      return LocatorFields(
        width: width,
        height: height,
        luma: luma,
        tanScore: tanScore,
        gradient: gradient,
        strictBoardMask: strictMask
      )
    }
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let index = y * width + x
        let horizontal = abs(luma[index + 1] - luma[index - 1])
        let vertical = abs(luma[index + width] - luma[index - width])
        gradient[index] = max(horizontal, vertical)
      }
    }
    return LocatorFields(
      width: width,
      height: height,
      luma: luma,
      tanScore: tanScore,
      gradient: gradient,
      strictBoardMask: strictMask
    )
  }

  private static func boardColorComponents(
    mask: [Bool],
    width: Int,
    height: Int
  ) -> [ColorComponent] {
    guard mask.count == width * height else { return [] }
    var visited = [Bool](repeating: false, count: mask.count)
    var components: [ColorComponent] = []
    var queue: [Int] = []
    queue.reserveCapacity(min(mask.count, 8192))

    for index in mask.indices {
      guard mask[index], !visited[index] else { continue }
      visited[index] = true
      queue.removeAll(keepingCapacity: true)
      queue.append(index)
      var head = 0
      var count = 0
      var minX = width
      var minY = height
      var maxX = 0
      var maxY = 0
      while head < queue.count {
        let current = queue[head]
        head += 1
        let x = current % width
        let y = current / width
        count += 1
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)

        let yStart = max(0, y - 1)
        let yEnd = min(height - 1, y + 1)
        let xStart = max(0, x - 1)
        let xEnd = min(width - 1, x + 1)
        for neighborY in yStart...yEnd {
          for neighborX in xStart...xEnd {
            let neighbor = neighborY * width + neighborX
            if mask[neighbor], !visited[neighbor] {
              visited[neighbor] = true
              queue.append(neighbor)
            }
          }
        }
      }
      if count > 120 {
        components.append(ColorComponent(count: count, minX: minX, minY: minY, maxX: maxX, maxY: maxY))
      }
    }

    components.sort { lhs, rhs in lhs.count > rhs.count }
    return components
  }

  private static func mergedBoardColorComponent(from components: [ColorComponent]) -> ColorComponent? {
    guard let base = components.first else { return nil }
    var merged = base
    let baseHeight = Double(max(1, base.height))
    let baseWidth = Double(max(1, base.width))
    for component in components.dropFirst() {
      let overlap = max(0, min(merged.maxX, component.maxX) - max(merged.minX, component.minX) + 1)
      let overlapFraction = Double(overlap) / Double(max(1, min(base.width, component.width)))
      let componentMinY = Double(component.minY)
      if componentMinY >= Double(base.minY) - 0.05 * baseHeight,
         componentMinY <= Double(merged.maxY) + 0.42 * baseHeight,
         overlapFraction > 0.45,
         Double(component.count) > 0.025 * Double(base.count),
         Double(component.width) > 0.18 * baseWidth {
        merged = ColorComponent(
          count: merged.count + component.count,
          minX: min(merged.minX, component.minX),
          minY: min(merged.minY, component.minY),
          maxX: max(merged.maxX, component.maxX),
          maxY: max(merged.maxY, component.maxY)
        )
      }
    }
    return merged
  }

  private static func refinedGridSearchQuad(
    _ initial: BoardQuad,
    fields: LocatorFields,
    bounds: LocatorBounds
  ) -> (quad: BoardQuad, score: Double) {
    let pixelScale = Double(min(fields.width, fields.height))
    let steps = [0.05, 0.025, 0.012, 0.006].map { max(1.0, $0 * pixelScale) }
    var bestQuad = clampedQuad(initial, to: bounds)
    var bestScore = scoreGridSearchQuad(bestQuad, fields: fields, bounds: bounds)
    for step in steps {
      var improved = true
      var iterations = 0
      while improved && iterations < 18 {
        improved = false
        iterations += 1
        for corner in 0..<4 {
          for axis in 0..<2 {
            for direction in [-1.0, 1.0] {
              var candidate = bestQuad
              moveCorner(&candidate, corner: corner, axis: axis, delta: direction * step)
              candidate = clampedQuad(candidate, to: bounds)
              let score = scoreGridSearchQuad(candidate, fields: fields, bounds: bounds)
              if score > bestScore + 1.0e-6 {
                bestQuad = candidate
                bestScore = score
                improved = true
              }
            }
          }
        }
      }
    }
    return (bestQuad, bestScore)
  }

  private static func regularizedLocatorQuad(_ quad: BoardQuad, fields: LocatorFields) -> BoardQuad {
    var regularized = quad
    let topLeftDrop = Double(regularized.topLeft.y - regularized.topRight.y)
    let maximumLooseDrop = Double(fields.height) * 0.12
    if topLeftDrop > maximumLooseDrop {
      regularized.topLeft.y = regularized.topRight.y + Double(fields.height) * 0.04
    }
    return regularized
  }

  private static func scoreGridSearchQuad(
    _ quad: BoardQuad,
    fields: LocatorFields,
    bounds: LocatorBounds
  ) -> Double {
    guard quadIsInsideBounds(quad, bounds),
          quadrilateralArea(quad) >= Double(fields.width * fields.height) * 0.03,
          quadrilateralArea(quad) <= Double(fields.width * fields.height) * 0.45,
          Double(quad.topRight.x - quad.topLeft.x) > Double(fields.width) * 0.22,
          Double(quad.bottomRight.x - quad.bottomLeft.x) > Double(fields.width) * 0.22,
          Double(quad.bottomLeft.y - quad.topLeft.y) > Double(fields.height) * 0.12,
          Double(quad.bottomRight.y - quad.topRight.y) > Double(fields.height) * 0.12 else {
      return -Double.infinity
    }

    let projection = ProjectiveQuadMapping(quad: quad)
    let corners = [
      projection.point(u: 0.0, v: 0.0),
      projection.point(u: 1.0, v: 0.0),
      projection.point(u: 1.0, v: 1.0),
      projection.point(u: 0.0, v: 1.0)
    ]
    let sideLengths = [
      distance(corners[0], corners[1]),
      distance(corners[1], corners[2]),
      distance(corners[2], corners[3]),
      distance(corners[3], corners[0])
    ]
    let step = max(2.0, (sideLengths.min() ?? 36.0) / 18.0)
    let offset = max(1.1, step * 0.24)
    var total = 0.0
    var sampleCount = 0
    var hitCount = 0

    func addLineSample(u: Double, v: Double, du: Double, dv: Double) {
      let point = projection.point(u: u, v: v)
      let next = projection.point(
        u: clamp(u + du, lower: 0.0, upper: 1.0),
        v: clamp(v + dv, lower: 0.0, upper: 1.0)
      )
      let dx = Double(next.x - point.x)
      let dy = Double(next.y - point.y)
      let length = sqrt(dx * dx + dy * dy)
      guard length > 1.0e-3 else { return }
      let normalX = -dy / length
      let normalY = dx / length
      guard let onLine = bilinear(fields.luma, width: fields.width, height: fields.height, x: Double(point.x), y: Double(point.y)),
            let offOne = bilinear(fields.luma, width: fields.width, height: fields.height, x: Double(point.x) + normalX * offset, y: Double(point.y) + normalY * offset),
            let offTwo = bilinear(fields.luma, width: fields.width, height: fields.height, x: Double(point.x) - normalX * offset, y: Double(point.y) - normalY * offset),
            let gradient = bilinear(fields.gradient, width: fields.width, height: fields.height, x: Double(point.x), y: Double(point.y)),
            let tanOne = bilinear(fields.tanScore, width: fields.width, height: fields.height, x: Double(point.x) + normalX * offset, y: Double(point.y) + normalY * offset),
            let tanTwo = bilinear(fields.tanScore, width: fields.width, height: fields.height, x: Double(point.x) - normalX * offset, y: Double(point.y) - normalY * offset) else {
        return
      }
      let tan = (tanOne + tanTwo) / 2.0
      let contrast = ((offOne + offTwo) / 2.0 - onLine) / 20.0
      let edge = gradient / 80.0
      total += clamp(contrast, lower: -1.0, upper: 3.0) * (0.5 + tan) +
        0.25 * min(2.0, edge) +
        0.1 * tan
      sampleCount += 1
      if contrast > 0.35 || edge > 0.5 {
        hitCount += 1
      }
    }

    for index in 0..<19 {
      let gridCoordinate = Double(index) / 18.0
      for sample in 1..<18 {
        let sampleCoordinate = Double(sample) / 18.0
        addLineSample(u: gridCoordinate, v: sampleCoordinate, du: 0.0, dv: 0.025)
        addLineSample(u: sampleCoordinate, v: gridCoordinate, du: 0.025, dv: 0.0)
      }
    }

    var tanSamples: [Double] = []
    tanSamples.reserveCapacity(81)
    for y in stride(from: 1, through: 17, by: 2) {
      for x in stride(from: 1, through: 17, by: 2) {
        let point = projection.point(u: Double(x) / 18.0, v: Double(y) / 18.0)
        if let tan = bilinear(
          fields.tanScore,
          width: fields.width,
          height: fields.height,
          x: Double(point.x),
          y: Double(point.y)
        ) {
          tanSamples.append(tan)
        }
      }
    }
    guard sampleCount >= 400, !tanSamples.isEmpty else {
      return -Double.infinity
    }
    tanSamples.sort()
    let tanMean = tanSamples.reduce(0.0, +) / Double(tanSamples.count)
    let tanFraction = Double(tanSamples.filter { $0 > 0.05 }.count) / Double(tanSamples.count)
    let tanP20 = tanSamples[min(tanSamples.count - 1, tanSamples.count / 5)]
    return total / Double(sampleCount) +
      0.7 * Double(hitCount) / Double(sampleCount) +
      0.35 * tanMean +
      0.25 * tanFraction +
      0.15 * tanP20
  }

  private static func bilinear(
    _ values: [Double],
    width: Int,
    height: Int,
    x: Double,
    y: Double
  ) -> Double? {
    guard x >= 0.0, y >= 0.0, x <= Double(width - 1), y <= Double(height - 1) else {
      return nil
    }
    let x0 = Int(floor(x))
    let y0 = Int(floor(y))
    let x1 = min(width - 1, x0 + 1)
    let y1 = min(height - 1, y0 + 1)
    let tx = x - Double(x0)
    let ty = y - Double(y0)
    let c00 = values[y0 * width + x0]
    let c10 = values[y0 * width + x1]
    let c01 = values[y1 * width + x0]
    let c11 = values[y1 * width + x1]
    return c00 * (1.0 - tx) * (1.0 - ty) +
      c10 * tx * (1.0 - ty) +
      c01 * (1.0 - tx) * ty +
      c11 * tx * ty
  }

  private static func clampedQuad(_ quad: BoardQuad, to bounds: LocatorBounds) -> BoardQuad {
    BoardQuad(
      topLeft: clampedPoint(quad.topLeft, to: bounds),
      topRight: clampedPoint(quad.topRight, to: bounds),
      bottomRight: clampedPoint(quad.bottomRight, to: bounds),
      bottomLeft: clampedPoint(quad.bottomLeft, to: bounds)
    )
  }

  private static func clampedPoint(_ point: CGPoint, to bounds: LocatorBounds) -> CGPoint {
    CGPoint(
      x: clamp(Double(point.x), lower: bounds.minX, upper: bounds.maxX),
      y: clamp(Double(point.y), lower: bounds.minY, upper: bounds.maxY)
    )
  }

  private static func moveCorner(_ quad: inout BoardQuad, corner: Int, axis: Int, delta: Double) {
    func moved(_ point: CGPoint) -> CGPoint {
      if axis == 0 {
        return CGPoint(x: Double(point.x) + delta, y: point.y)
      }
      return CGPoint(x: point.x, y: Double(point.y) + delta)
    }
    switch corner {
    case 0:
      quad.topLeft = moved(quad.topLeft)
    case 1:
      quad.topRight = moved(quad.topRight)
    case 2:
      quad.bottomRight = moved(quad.bottomRight)
    default:
      quad.bottomLeft = moved(quad.bottomLeft)
    }
  }

  private static func quadIsInsideBounds(_ quad: BoardQuad, _ bounds: LocatorBounds) -> Bool {
    pointIsInsideBounds(quad.topLeft, bounds) &&
      pointIsInsideBounds(quad.topRight, bounds) &&
      pointIsInsideBounds(quad.bottomRight, bounds) &&
      pointIsInsideBounds(quad.bottomLeft, bounds)
  }

  private static func pointIsInsideBounds(_ point: CGPoint, _ bounds: LocatorBounds) -> Bool {
    let x = Double(point.x)
    let y = Double(point.y)
    return x >= bounds.minX &&
      x <= bounds.maxX &&
      y >= bounds.minY &&
      y <= bounds.maxY
  }

  private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(upper, max(lower, value))
  }

  private static func estimateBoardQuad(in raster: Raster) -> BoardQuad? {
    var darkPixels: [CGPoint] = []
    darkPixels.reserveCapacity(raster.width * raster.height / 20)
    for y in 0..<raster.height {
      for x in 0..<raster.width where raster.luma(x: x, y: y) < 80.0 {
        darkPixels.append(CGPoint(x: Double(x), y: Double(y)))
      }
    }
    guard darkPixels.count > 400 else { return nil }

    let topLeft = darkPixels.min { lhs, rhs in lhs.x + lhs.y < rhs.x + rhs.y }
    let bottomRight = darkPixels.max { lhs, rhs in lhs.x + lhs.y < rhs.x + rhs.y }
    let topRight = darkPixels.max { lhs, rhs in lhs.x - lhs.y < rhs.x - rhs.y }
    let bottomLeft = darkPixels.min { lhs, rhs in lhs.x - lhs.y < rhs.x - rhs.y }
    guard let topLeft, let topRight, let bottomRight, let bottomLeft else { return nil }

    let quad = BoardQuad(
      topLeft: topLeft,
      topRight: topRight,
      bottomRight: bottomRight,
      bottomLeft: bottomLeft
    )
    guard quadrilateralArea(quad) >= Double(raster.width * raster.height) * 0.20 else {
      return nil
    }
    guard distance(topLeft, topRight) > 0,
          distance(topRight, bottomRight) > 0,
          distance(bottomLeft, bottomRight) > 0,
          distance(topLeft, bottomLeft) > 0 else {
      return nil
    }
    return quad
  }

  private static func estimateWarmBoardQuad(in raster: Raster) -> BoardQuad? {
    let sampleStride = max(1, min(raster.width, raster.height) / 700)
    var points: [CGPoint] = []
    points.reserveCapacity(raster.width * raster.height / (sampleStride * sampleStride * 12))
    for y in stride(from: 0, to: raster.height, by: sampleStride) {
      for x in stride(from: 0, to: raster.width, by: sampleStride) where raster.isLikelyBoardBackground(x: x, y: y) {
        points.append(CGPoint(x: Double(x), y: Double(y)))
      }
    }
    guard points.count > 600 else { return nil }

    let xs = points.map { Double($0.x) }.sorted()
    let ys = points.map { Double($0.y) }.sorted()
    let minX = percentile(xs, 0.01)
    let maxX = percentile(xs, 0.99)
    let minY = percentile(ys, 0.01)
    let maxY = percentile(ys, 0.99)
    let filtered = points.filter { point in
      point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
    guard filtered.count > 600 else { return nil }

    let topLeft = averageExtreme(filtered) { $0.x + $0.y < $1.x + $1.y }
    let topRight = averageExtreme(filtered) { $0.x - $0.y > $1.x - $1.y }
    let bottomRight = averageExtreme(filtered) { $0.x + $0.y > $1.x + $1.y }
    let bottomLeft = averageExtreme(filtered) { $0.x - $0.y < $1.x - $1.y }
    let quad = BoardQuad(
      topLeft: topLeft,
      topRight: topRight,
      bottomRight: bottomRight,
      bottomLeft: bottomLeft
    )
    let area = quadrilateralArea(quad)
    guard area >= Double(raster.width * raster.height) * 0.08 else { return nil }
    guard distance(quad.topLeft, quad.topRight) > Double(raster.width) * 0.18,
          distance(quad.bottomLeft, quad.bottomRight) > Double(raster.width) * 0.18,
          distance(quad.topLeft, quad.bottomLeft) > Double(raster.height) * 0.18,
          distance(quad.topRight, quad.bottomRight) > Double(raster.height) * 0.18 else {
      return nil
    }
    return quad
  }

  private static func percentile(_ sortedValues: [Double], _ fraction: Double) -> Double {
    guard !sortedValues.isEmpty else { return 0.0 }
    let index = min(sortedValues.count - 1, max(0, Int(Double(sortedValues.count - 1) * fraction)))
    return sortedValues[index]
  }

  private static func averageExtreme(
    _ points: [CGPoint],
    by areInIncreasingOrder: (CGPoint, CGPoint) -> Bool
  ) -> CGPoint {
    let count = max(12, points.count / 80)
    let selected = points.sorted(by: areInIncreasingOrder).prefix(count)
    var totalX = 0.0
    var totalY = 0.0
    var total = 0.0
    for point in selected {
      totalX += point.x
      totalY += point.y
      total += 1.0
    }
    guard total > 0 else { return .zero }
    return CGPoint(x: totalX / total, y: totalY / total)
  }

  private static func interpolate(quad: BoardQuad, u: Double, v: Double) -> CGPoint {
    let top = CGPoint(
      x: quad.topLeft.x * (1.0 - u) + quad.topRight.x * u,
      y: quad.topLeft.y * (1.0 - u) + quad.topRight.y * u
    )
    let bottom = CGPoint(
      x: quad.bottomLeft.x * (1.0 - u) + quad.bottomRight.x * u,
      y: quad.bottomLeft.y * (1.0 - u) + quad.bottomRight.y * u
    )
    return CGPoint(
      x: top.x * (1.0 - v) + bottom.x * v,
      y: top.y * (1.0 - v) + bottom.y * v
    )
  }

  private static func quadrilateralArea(_ quad: BoardQuad) -> Double {
    let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
    var total = 0.0
    for index in points.indices {
      let next = points[(index + 1) % points.count]
      total += points[index].x * next.y - next.x * points[index].y
    }
    return abs(total) / 2.0
  }

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)
  }

  private static func verticalDarkProjection(_ raster: Raster) -> [Int] {
    (0..<raster.width).map { x in
      var count = 0
      for y in 0..<raster.height where raster.luma(x: x, y: y) < 100.0 {
        count += 1
      }
      return count
    }
  }

  private static func horizontalDarkProjection(_ raster: Raster) -> [Int] {
    (0..<raster.height).map { y in
      var count = 0
      for x in 0..<raster.width where raster.luma(x: x, y: y) < 100.0 {
        count += 1
      }
      return count
    }
  }

  private struct LineDetection {
    var centers: [Double] = []
    var widths: [Int] = []
    var weights: [Int] = []
    var maxProjection = 0
  }

  private static func detectLines(in projection: [Int]) -> LineDetection {
    guard let maxProjection = projection.max(), maxProjection > 0 else { return LineDetection() }
    let threshold = max(24, Int(Double(maxProjection) * 0.55))
    var groups: [(center: Double, width: Int, weight: Int)] = []
    var index = 0
    while index < projection.count {
      if projection[index] < threshold {
        index += 1
        continue
      }
      let start = index
      var weighted = 0
      var total = 0
      while index < projection.count, projection[index] >= threshold {
        weighted += index * projection[index]
        total += projection[index]
        index += 1
      }
      if total > 0 {
        groups.append((center: Double(weighted) / Double(total), width: index - start, weight: total))
      } else {
        groups.append((center: Double(start + index - 1) / 2.0, width: index - start, weight: 0))
      }
    }
    if groups.count > 19 {
      groups = groups.sorted { $0.weight > $1.weight }.prefix(19).sorted { $0.center < $1.center }
    }
    return LineDetection(
      centers: groups.map(\.center),
      widths: groups.map(\.width),
      weights: groups.map(\.weight),
      maxProjection: maxProjection
    )
  }

  private static func isUsableAxisAlignedGrid(_ detection: LineDetection, crossExtent: Int) -> Bool {
    guard detection.centers.count == 19, detection.widths.count == 19, detection.weights.count == 19 else {
      return false
    }
    let gap = medianGap(detection.centers)
    guard gap.isFinite, gap > 0 else { return false }

    let gaps = zip(detection.centers.dropFirst(), detection.centers).map { $0 - $1 }
    guard gaps.allSatisfy({ $0 > gap * 0.72 && $0 < gap * 1.28 }) else {
      return false
    }

    let maximumLineWidth = max(8, Int(ceil(gap * 0.16)))
    guard detection.widths.allSatisfy({ $0 > 0 && $0 <= maximumLineWidth }) else {
      return false
    }

    guard let lightestLine = detection.weights.min(),
          let strongestLine = detection.weights.max(),
          strongestLine > 0 else {
      return false
    }
    let weightRatio = Double(lightestLine) / Double(strongestLine)
    guard weightRatio >= 0.18 else { return false }

    return detection.maxProjection >= max(24, Int(Double(crossExtent) * 0.32))
  }

  private static func medianGap(_ centers: [Double]) -> Double {
    let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }.sorted()
    guard !gaps.isEmpty else { return 1.0 }
    return gaps[gaps.count / 2]
  }

  private static func sampleIntersection(
    _ raster: Raster,
    centerX: Double,
    centerY: Double,
    radius: Double
  ) -> (
    meanLuma: Double,
    darkFraction: Double,
    brightFraction: Double,
    lumaStdDev: Double,
    centerMeanLuma: Double,
    outerMeanLuma: Double,
    neutralBrightFraction: Double,
    meanSaturation: Double,
    outerMeanSaturation: Double
  ) {
    let outerRadius = radius * 1.85
    let minX = max(0, Int(floor(centerX - outerRadius)))
    let maxX = min(raster.width - 1, Int(ceil(centerX + outerRadius)))
    let minY = max(0, Int(floor(centerY - outerRadius)))
    let maxY = min(raster.height - 1, Int(ceil(centerY + outerRadius)))
    let radiusSquared = radius * radius
    var count = 0
    var dark = 0
    var bright = 0
    var neutralBright = 0
    var total = 0.0
    var totalSquares = 0.0
    var totalSaturation = 0.0
    var centerCount = 0
    var centerTotal = 0.0
    var outerCount = 0
    var outerTotal = 0.0
    var outerSaturationTotal = 0.0
    let outerRadiusSquared = radiusSquared * 1.85 * 1.85
    let annulusInnerRadiusSquared = radiusSquared * 1.35 * 1.35
    for y in minY...maxY {
      for x in minX...maxX {
        let dx = Double(x) - centerX
        let dy = Double(y) - centerY
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared <= outerRadiusSquared else { continue }
        let luma = raster.luma(x: x, y: y)
        let color = raster.rgb(x: x, y: y)
        let maxChannel = max(color.red, max(color.green, color.blue))
        let minChannel = min(color.red, min(color.green, color.blue))
        let saturation = maxChannel <= 0.0 ? 0.0 : (maxChannel - minChannel) / maxChannel
        if distanceSquared <= radiusSquared {
          total += luma
          totalSquares += luma * luma
          totalSaturation += saturation
          count += 1
          if luma < 90.0 { dark += 1 }
          if luma > 174.0 { bright += 1 }
          if luma > 115.0 && maxChannel - minChannel < 48.0 {
            neutralBright += 1
          }
          if distanceSquared <= radiusSquared * 0.45 * 0.45 {
            centerTotal += luma
            centerCount += 1
          }
        } else if distanceSquared >= annulusInnerRadiusSquared {
          outerTotal += luma
          outerSaturationTotal += saturation
          outerCount += 1
        }
      }
    }
    guard count > 0 else { return (255.0, 0.0, 0.0, 0.0, 255.0, 255.0, 0.0, 0.0, 0.0) }
    let mean = total / Double(count)
    let variance = max(0.0, totalSquares / Double(count) - mean * mean)
    return (
      mean,
      Double(dark) / Double(count),
      Double(bright) / Double(count),
      sqrt(variance),
      centerCount > 0 ? centerTotal / Double(centerCount) : mean,
      outerCount > 0 ? outerTotal / Double(outerCount) : mean,
      Double(neutralBright) / Double(count),
      totalSaturation / Double(count),
      outerCount > 0 ? outerSaturationTotal / Double(outerCount) : totalSaturation / Double(count)
    )
  }
}

private struct Raster {
  var width: Int
  var height: Int
  var pixels: [UInt8]

  init(image: CGImage) throws {
    width = image.width
    height = image.height
    pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw QixiBoardImageRecognizer.RecognitionError.unreadableImage
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }

  func luma(x: Int, y: Int) -> Double {
    let offset = (y * width + x) * 4
    let red = Double(pixels[offset])
    let green = Double(pixels[offset + 1])
    let blue = Double(pixels[offset + 2])
    return red * 0.299 + green * 0.587 + blue * 0.114
  }

  func isLikelyBoardBackground(x: Int, y: Int) -> Bool {
    let offset = (y * width + x) * 4
    let red = Double(pixels[offset])
    let green = Double(pixels[offset + 1])
    let blue = Double(pixels[offset + 2])
    let maxChannel = max(red, max(green, blue))
    let minChannel = min(red, min(green, blue))
    let saturation = maxChannel <= 0.0 ? 0.0 : (maxChannel - minChannel) / maxChannel
    let luma = red * 0.299 + green * 0.587 + blue * 0.114
    return red > green * 0.78 &&
      green > blue * 1.08 &&
      red > blue * 1.18 &&
      red - green < 96.0 &&
      saturation > 0.10 &&
      luma > 55.0 &&
      luma < 212.0
  }

  func rgb(x: Int, y: Int) -> (red: Double, green: Double, blue: Double) {
    let offset = (y * width + x) * 4
    return (
      Double(pixels[offset]),
      Double(pixels[offset + 1]),
      Double(pixels[offset + 2])
    )
  }

  func sampleRGBA(x: Double, y: Double) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let clampedX = min(max(x, 0.0), Double(width - 1))
    let clampedY = min(max(y, 0.0), Double(height - 1))
    let x0 = Int(floor(clampedX))
    let y0 = Int(floor(clampedY))
    let x1 = min(width - 1, x0 + 1)
    let y1 = min(height - 1, y0 + 1)
    let tx = clampedX - Double(x0)
    let ty = clampedY - Double(y0)
    let c00 = rgba(x: x0, y: y0)
    let c10 = rgba(x: x1, y: y0)
    let c01 = rgba(x: x0, y: y1)
    let c11 = rgba(x: x1, y: y1)
    return (
      red: bilinear(c00.red, c10.red, c01.red, c11.red, tx: tx, ty: ty),
      green: bilinear(c00.green, c10.green, c01.green, c11.green, tx: tx, ty: ty),
      blue: bilinear(c00.blue, c10.blue, c01.blue, c11.blue, tx: tx, ty: ty),
      alpha: bilinear(c00.alpha, c10.alpha, c01.alpha, c11.alpha, tx: tx, ty: ty)
    )
  }

  private func rgba(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let offset = (y * width + x) * 4
    return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
  }

  private func bilinear(_ c00: UInt8, _ c10: UInt8, _ c01: UInt8, _ c11: UInt8, tx: Double, ty: Double) -> UInt8 {
    let top = Double(c00) * (1.0 - tx) + Double(c10) * tx
    let bottom = Double(c01) * (1.0 - tx) + Double(c11) * tx
    let value = top * (1.0 - ty) + bottom * ty
    return UInt8(min(255.0, max(0.0, round(value))))
  }
}
