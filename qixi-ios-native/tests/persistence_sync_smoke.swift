import Foundation
import CoreGraphics
import ImageIO

final class QixiUnknownSizeFileManager: FileManager {
  override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
    throw NSError(domain: "QixiUnknownSizeFileManager", code: 1)
  }
}

@main
struct PersistenceSyncSmoke {
  static func main() throws {
    guard let fixedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !fixedHome.isEmpty else {
      fail("CFFIXED_USER_HOME must point to a temporary test home")
    }

    let snapshotsRoot = QixiSnapshotStore.snapshotsDirectory
    try? FileManager.default.removeItem(at: snapshotsRoot)

    let baseDate = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 3_600)
    let original = snapshot(
      savedAt: baseDate,
      reason: "roundTrip",
      currentPly: 2,
      engine: .b18nbt,
      winrate: 0.612,
      scoreMean: 4.25
    )

    let encoded = try QixiSnapshotStore.encode(original)
    guard let decoded = try QixiSnapshotStore.decode(encoded) else {
      fail("current schema snapshot decoded as nil")
    }
    expect(decoded == original, "snapshot encode/decode preserves semantic state")
    let encodedPayload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    expect(encodedPayload["rootNoise"] == nil, "snapshot JSON excludes nonpersistent root noise")
    var rootNoisePollutedPayload = encodedPayload
    rootNoisePollutedPayload["rootNoise"] = 0.37
    let rootNoisePollutedData = try JSONSerialization.data(withJSONObject: rootNoisePollutedPayload, options: [.sortedKeys])
    guard let rootNoisePollutedDecoded = try QixiSnapshotStore.decode(rootNoisePollutedData) else {
      fail("root-noise-polluted current schema snapshot decoded as nil")
    }
    expect(
      rootNoisePollutedDecoded == original,
      "snapshot decode ignores nonpersistent root noise payloads"
    )
    expect(
      QixiSyncStore.launchSyncEnabled(
        requestedEnabled: true,
        automationOverride: nil,
        provider: .localFallback
      ) == false,
      "launch does not present local sync fallback as enabled iCloud"
    )
    expect(
      QixiSyncStore.launchSyncEnabled(
        requestedEnabled: true,
        automationOverride: nil,
        provider: .iCloud
      ) == true,
      "launch preserves requested iCloud sync when an iCloud provider is available"
    )
    expect(
      QixiSyncStore.launchSyncEnabled(
        requestedEnabled: false,
        automationOverride: nil,
        provider: .iCloud
      ) == false,
      "launch keeps iCloud disabled when the user did not request sync"
    )
    expect(
      QixiSyncStore.launchSyncEnabled(
        requestedEnabled: false,
        automationOverride: true,
        provider: .localFallback
      ) == true,
      "launch automation override can force iCloud sync visual states"
    )
    expect(
      QixiSyncStore.launchSyncEnabled(
        requestedEnabled: true,
        automationOverride: false,
        provider: .iCloud
      ) == false,
      "launch automation override can force iCloud sync disabled visual states"
    )
    expect(
      QixiSyncStore.persistedICloudEnabled(afterSyncWith: .localFallback) == false,
      "manual sync does not persist local fallback as enabled iCloud"
    )
    expect(
      QixiSyncStore.persistedICloudEnabled(afterSyncWith: .iCloud) == true,
      "manual sync persists enabled iCloud only after real iCloud reconciliation"
    )
    let visiblePackageDestination = QixiSyncStore.visibleMCTSStatePackageDestination()
    expect(
      visiblePackageDestination.packageURL.lastPathComponent == QixiSyncStore.visibleMCTSStatePackageFilename,
      "sync exposes a stable user-visible MCTS state package filename"
    )
    expect(
      QixiSyncStore.visibleMCTSStatePackageRelativePath.hasSuffix(QixiSyncStore.visibleMCTSStatePackageFilename),
      "visible MCTS state package relative path ends with the importable package filename"
    )
    let visiblePackageSource = try QixiMCTSStatePackageStore.freshTemporaryPackageURL()
    defer {
      try? FileManager.default.removeItem(at: visiblePackageSource)
    }
    try QixiMCTSStatePackageStore.writeSnapshot(original, to: visiblePackageSource)
    try QixiMCTSStatePackageStore.writeManifest(
      snapshot: original,
      includesEngineTombstone: false,
      to: visiblePackageSource,
      exportedAt: baseDate
    )
    let visiblePackageURL = try QixiSyncStore.replaceVisibleMCTSStatePackage(with: visiblePackageSource)
    expect(
      visiblePackageURL.lastPathComponent == QixiSyncStore.visibleMCTSStatePackageFilename,
      "sync writes the importable MCTS state package at the visible package destination"
    )
    let visiblePackageImport = try QixiMCTSStatePackageStore.loadPackage(from: visiblePackageURL)
    expect(
      visiblePackageImport.snapshot.hasSameRestorableState(as: original) &&
        visiblePackageImport.engineTombstoneURL == nil,
      "visible sync MCTS state package can be loaded by the normal MCTS-state importer"
    )
    let duplicateTopLevelSnapshotData = dataByReplacingFirst(
      in: encoded,
      "\"schemaVersion\":1",
      "\"schemaVersion\":1,\"schemaVersion\":1"
    )
    expectThrows("snapshot decode rejects duplicate top-level JSON keys") {
      _ = try QixiSnapshotStore.decode(duplicateTopLevelSnapshotData)
    }
    let duplicateNestedSnapshotData = dataByReplacingFirst(
      in: encoded,
      "\"rank\":1",
      "\"rank\":1,\"rank\":2"
    )
    expectThrows("snapshot decode rejects nested duplicate JSON keys") {
      _ = try QixiSnapshotStore.decode(duplicateNestedSnapshotData)
    }
    let nonStandardSnapshotData = dataByReplacingFirst(
      in: encoded,
      "\"komi\":7.5",
      "\"komi\":NaN"
    )
    expectThrows("snapshot decode rejects non-standard JSON constants") {
      _ = try QixiSnapshotStore.decode(nonStandardSnapshotData)
    }
    expectThrows("snapshot decode rejects non-object JSON documents") {
      _ = try QixiSnapshotStore.decode(Data("[]".utf8))
    }
    expectThrows("snapshot decode rejects oversized JSON documents before decoding") {
      _ = try QixiSnapshotStore.decode(Data(repeating: 0x20, count: QixiSnapshotStore.maxSnapshotBytes + 1))
    }
    let oversizedSnapshotURL = snapshotsRoot.appendingPathComponent("oversized-autosave.qixi-state.json")
    try FileManager.default.createDirectory(at: snapshotsRoot, withIntermediateDirectories: true)
    try writeSparseFile(at: oversizedSnapshotURL, byteCount: UInt64(QixiSnapshotStore.maxSnapshotBytes + 1))
    expectThrows("snapshot URL decode rejects oversized JSON files before loading") {
      _ = try QixiSnapshotStore.decode(from: oversizedSnapshotURL)
    }
    let linkedSnapshotTargetURL = snapshotsRoot.appendingPathComponent("linked-snapshot-target.qixi-state.json")
    try encoded.write(to: linkedSnapshotTargetURL, options: [.atomic])
    let linkedSnapshotURL = snapshotsRoot.appendingPathComponent("linked-autosave.qixi-state.json")
    try? FileManager.default.removeItem(at: linkedSnapshotURL)
    try FileManager.default.createSymbolicLink(at: linkedSnapshotURL, withDestinationURL: linkedSnapshotTargetURL)
    expectThrowsContaining(
      "snapshot URL decode rejects symbolic-link files before loading",
      "symbolic links"
    ) {
      _ = try QixiSnapshotStore.decode(from: linkedSnapshotURL)
    }
    try? FileManager.default.removeItem(at: linkedSnapshotURL)
    let directorySnapshotURL = snapshotsRoot.appendingPathComponent("directory-autosave.qixi-state.json", isDirectory: true)
    try? FileManager.default.removeItem(at: directorySnapshotURL)
    try FileManager.default.createDirectory(at: directorySnapshotURL, withIntermediateDirectories: true)
    expectThrowsContaining(
      "snapshot URL decode rejects non-regular files before FileHandle read",
      "regular file"
    ) {
      _ = try QixiSnapshotStore.decode(from: directorySnapshotURL)
    }
    try? FileManager.default.removeItem(at: directorySnapshotURL)
    try? FileManager.default.removeItem(at: QixiSnapshotStore.snapshotURL)
    try FileManager.default.createSymbolicLink(at: QixiSnapshotStore.snapshotURL, withDestinationURL: linkedSnapshotTargetURL)
    expectThrowsContaining(
      "snapshot save rejects symbolic-link primary paths",
      "symbolic links"
    ) {
      try QixiSnapshotStore.save(original)
    }
    try? FileManager.default.removeItem(at: QixiSnapshotStore.snapshotURL)
    try? FileManager.default.removeItem(at: linkedSnapshotTargetURL)
    let linkedSnapshotsDirectoryTargetURL = snapshotsRoot
      .deletingLastPathComponent()
      .appendingPathComponent("linked-qixi-snapshots-directory-target", isDirectory: true)
    try? FileManager.default.removeItem(at: snapshotsRoot)
    try? FileManager.default.removeItem(at: linkedSnapshotsDirectoryTargetURL)
    try FileManager.default.createDirectory(at: linkedSnapshotsDirectoryTargetURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: snapshotsRoot, withDestinationURL: linkedSnapshotsDirectoryTargetURL)
    expectThrowsContaining(
      "snapshot save rejects symbolic-link snapshot directories",
      "symbolic links"
    ) {
      try QixiSnapshotStore.save(original)
    }
    try? FileManager.default.removeItem(at: snapshotsRoot)
    try? FileManager.default.removeItem(at: linkedSnapshotsDirectoryTargetURL)
    try FileManager.default.createDirectory(at: snapshotsRoot, withIntermediateDirectories: true)
    let unknownSizeOversizedJSONURL = snapshotsRoot.appendingPathComponent("unknown-size-strict-json.json")
    try Data("{\"a\":1}    ".utf8).write(to: unknownSizeOversizedJSONURL, options: [.atomic])
    do {
      _ = try QixiStrictJSONDocumentValidator.validatedObjectData(
        from: unknownSizeOversizedJSONURL,
        label: "unknown-size strict JSON",
        maxBytes: 8,
        fileManager: QixiUnknownSizeFileManager()
      )
      fail("unknown-size strict JSON should be rejected by opened descriptor byte count")
    } catch QixiStrictJSONError.documentTooLarge(let label, let bytes, let limit) {
      expect(
        label == "unknown-size strict JSON" && bytes == 11 && limit == 8,
        "file-backed strict JSON validator rejects opened file byte count when file size is unavailable"
      )
    }
    let repeatedHistory = [
      BoardMove(color: .black, x: 1, y: 0),
      BoardMove(color: .white, x: 0, y: 0),
      BoardMove(color: .black, x: 0, y: 1),
      BoardMove(pass: .white),
      BoardMove(color: .black, x: 0, y: 0)
    ]
    let repeatedHistorySnapshot = snapshot(
      savedAt: baseDate.addingTimeInterval(15),
      reason: "repeatedHistory",
      currentPly: repeatedHistory.count,
      engine: .b6,
      winrate: 0.58,
      scoreMean: 1.75,
      mainLine: repeatedHistory
    )
    let repeatedHistoryData = try QixiSnapshotStore.encode(repeatedHistorySnapshot)
    guard let repeatedHistoryDecoded = try QixiSnapshotStore.decode(repeatedHistoryData) else {
      fail("repeated-coordinate current schema snapshot decoded as nil")
    }
    expect(
      repeatedHistoryDecoded.mainLine == repeatedHistory &&
        repeatedHistoryDecoded.currentPly == repeatedHistory.count,
      "snapshot encode/decode preserves repeated-coordinate ordered history"
    )
    try QixiSyncStore.write(repeatedHistorySnapshot)
    let repeatedHistoryLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: nil, syncEnabled: true)
    expect(
      repeatedHistoryLaunch?.mainLine == repeatedHistory &&
        repeatedHistoryLaunch?.currentPly == repeatedHistory.count,
      "sync launch restore preserves repeated-coordinate ordered history"
    )
    var longMixedHistory: [BoardMove] = []
    longMixedHistory.reserveCapacity(2_048)
    let legalOpeningPoints = [
      (3, 3), (15, 15), (3, 15), (15, 3),
      (9, 9), (4, 10), (10, 4), (16, 10)
    ]
    for index in 0..<2_048 {
      if index < legalOpeningPoints.count {
        let point = legalOpeningPoints[index]
        longMixedHistory.append(BoardMove(color: index.isMultiple(of: 2) ? .black : .white, x: point.0, y: point.1))
      } else {
        longMixedHistory.append(BoardMove(pass: index.isMultiple(of: 2) ? .black : .white))
      }
    }
    expect(QixiBoardPosition.firstIllegalMoveIndex(in: longMixedHistory) == nil, "board legality validates long mixed histories without replaying every prefix")
    let longMixedHistorySnapshot = snapshot(
      savedAt: baseDate.addingTimeInterval(15.5),
      reason: "longMixedHistory",
      currentPly: longMixedHistory.count,
      engine: .b6,
      winrate: 0.54,
      scoreMean: 0.75,
      mainLine: longMixedHistory
    )
    let longMixedHistoryData = try QixiSnapshotStore.encode(longMixedHistorySnapshot)
    guard let longMixedHistoryDecoded = try QixiSnapshotStore.decode(longMixedHistoryData) else {
      fail("long mixed-history current schema snapshot decoded as nil")
    }
    expect(
      longMixedHistoryDecoded.currentPly == longMixedHistory.count &&
        longMixedHistoryDecoded.mainLine.count == longMixedHistory.count,
      "snapshot encode/decode preserves long mixed histories with bounded legality validation"
    )
    let sameStonesHistoryA = [
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 15),
      BoardMove(color: .black, x: 3, y: 15),
      BoardMove(color: .white, x: 15, y: 3)
    ]
    let sameStonesHistoryB = [
      BoardMove(color: .black, x: 3, y: 15),
      BoardMove(color: .white, x: 15, y: 3),
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 15, y: 15)
    ]
    expect(
      QixiBoardPosition.visibleStones(after: sameStonesHistoryA) ==
        QixiBoardPosition.visibleStones(after: sameStonesHistoryB),
      "same-stones history fixture has an identical visible board"
    )
    let sameStonesKeyA = QixiPositionIdentity.cacheKey(
      engine: .b18nbt,
      moves: sameStonesHistoryA,
      komi: 7.5,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    let sameStonesKeyB = QixiPositionIdentity.cacheKey(
      engine: .b18nbt,
      moves: sameStonesHistoryB,
      komi: 7.5,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    expect(
      sameStonesKeyA != sameStonesKeyB,
      "semantic position cache key distinguishes identical stones with different ordered history"
    )
    let sameHistoryDifferentSettingsKey = QixiPositionIdentity.cacheKey(
      engine: .b18nbt,
      moves: sameStonesHistoryA,
      komi: 6.5,
      rootNoise: 0.04
    )
    let sameStonesSeparatedCaches = QixiAppSnapshot(
      savedAt: baseDate.addingTimeInterval(16),
      saveReason: "sameStonesDifferentHistoryCaches",
      selectedEngine: .b18nbt,
      currentPly: sameStonesHistoryA.count,
      mainLine: sameStonesHistoryA,
      recognizedSetupStones: nil,
      komi: 7.5,
      showTerritory: true,
      analysisByEngine: [
        AnalysisEngine.b18nbt.rawValue: [
          sameStonesKeyA: cachedAnalysis(savedAt: baseDate.addingTimeInterval(16), positionKey: sameStonesKeyA, winrate: 0.62, scoreMean: 3.5),
          sameStonesKeyB: cachedAnalysis(savedAt: baseDate.addingTimeInterval(17), positionKey: sameStonesKeyB, winrate: 0.43, scoreMean: -2.25),
          sameHistoryDifferentSettingsKey: cachedAnalysis(savedAt: baseDate.addingTimeInterval(18), positionKey: sameHistoryDifferentSettingsKey, winrate: 0.57, scoreMean: 1.75)
        ]
      ]
    )
    let sameStonesSeparatedData = try QixiSnapshotStore.encode(sameStonesSeparatedCaches)
    guard let sameStonesSeparatedDecoded = try QixiSnapshotStore.decode(sameStonesSeparatedData) else {
      fail("same-stones separated-cache snapshot decoded as nil")
    }
    let decodedSameStonesCaches = sameStonesSeparatedDecoded.analysisByEngine[AnalysisEngine.b18nbt.rawValue] ?? [:]
    expect(
      decodedSameStonesCaches[sameStonesKeyA]?.winrate == 0.62 &&
        decodedSameStonesCaches[sameStonesKeyB]?.winrate == 0.43 &&
        decodedSameStonesCaches[sameHistoryDifferentSettingsKey]?.winrate == 0.57,
      "snapshot encode/decode preserves distinct cached analysis for identical stones, different history, and different valid settings"
    )
    try QixiSyncStore.write(sameStonesSeparatedCaches)
    guard let sameStonesSynced = try QixiSyncStore.launchSnapshot(localSnapshot: nil, syncEnabled: true) else {
      fail("same-stones separated-cache sync restore returned nil")
    }
    let syncedSameStonesCaches = sameStonesSynced.analysisByEngine[AnalysisEngine.b18nbt.rawValue] ?? [:]
    expect(
      syncedSameStonesCaches[sameStonesKeyA]?.scoreMean == 3.5 &&
        syncedSameStonesCaches[sameStonesKeyB]?.scoreMean == -2.25 &&
        syncedSameStonesCaches[sameHistoryDifferentSettingsKey]?.scoreMean == 1.75,
      "sync restore preserves distinct cached analysis for identical stones, different history, and different valid settings"
    )
    let illegalHistory = [
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(color: .white, x: 4, y: 3),
      BoardMove(color: .black, x: 3, y: 3)
    ]
    let illegalHistorySnapshot = snapshot(
      savedAt: baseDate.addingTimeInterval(18),
      reason: "illegalHistory",
      currentPly: illegalHistory.count,
      engine: .b6,
      winrate: 0.51,
      scoreMean: 0.25,
      mainLine: illegalHistory
    )
    expectThrows("snapshot encode rejects illegal repeated-coordinate history") {
      _ = try QixiSnapshotStore.encode(illegalHistorySnapshot)
    }
    expectThrows("snapshot save rejects illegal repeated-coordinate history") {
      try QixiSnapshotStore.save(illegalHistorySnapshot)
    }
    let illegalHistoryData = try rawSnapshotData(illegalHistorySnapshot)
    let illegalHistoryDecoded = try QixiSnapshotStore.decode(illegalHistoryData)
    expect(illegalHistoryDecoded == nil, "snapshot decode rejects illegal repeated-coordinate history")

    let negativePlySnapshot = snapshot(
      savedAt: baseDate.addingTimeInterval(19),
      reason: "negativeCurrentPly",
      currentPly: -1,
      engine: .b6,
      winrate: 0.52,
      scoreMean: 0.5
    )
    expectThrows("snapshot encode rejects negative current ply") {
      _ = try QixiSnapshotStore.encode(negativePlySnapshot)
    }
    expectThrows("snapshot save rejects negative current ply") {
      try QixiSnapshotStore.save(negativePlySnapshot)
    }
    let negativePlyDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(negativePlySnapshot))
    expect(negativePlyDecoded == nil, "snapshot decode rejects negative current ply")

    let beyondEndPlySnapshot = snapshot(
      savedAt: baseDate.addingTimeInterval(20),
      reason: "beyondEndCurrentPly",
      currentPly: 99,
      engine: .b6,
      winrate: 0.53,
      scoreMean: 0.75
    )
    expectThrows("snapshot encode rejects current ply beyond main-line count") {
      _ = try QixiSnapshotStore.encode(beyondEndPlySnapshot)
    }
    expectThrows("snapshot save rejects current ply beyond main-line count") {
      try QixiSnapshotStore.save(beyondEndPlySnapshot)
    }
    let beyondEndPlyDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(beyondEndPlySnapshot))
    expect(beyondEndPlyDecoded == nil, "snapshot decode rejects current ply beyond main-line count")

    let invalidKomiSnapshot = snapshot(
      savedAt: baseDate.addingTimeInterval(21),
      reason: "invalidKomi",
      currentPly: 2,
      engine: .b6,
      winrate: 0.54,
      scoreMean: 0.8,
      komi: 151.0
    )
    expectThrows("snapshot encode rejects komi outside supported range") {
      _ = try QixiSnapshotStore.encode(invalidKomiSnapshot)
    }
    expectThrows("snapshot save rejects komi outside supported range") {
      try QixiSnapshotStore.save(invalidKomiSnapshot)
    }
    let invalidKomiDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(invalidKomiSnapshot))
    expect(invalidKomiDecoded == nil, "snapshot decode rejects komi outside supported range")

    let offBoardCandidateSnapshot = snapshotWithMutatedCache(original) { cache in
      cache.candidates[0].x = QixiBoardPosition.boardSize
    }
    expectThrows("snapshot encode rejects off-board cached candidate") {
      _ = try QixiSnapshotStore.encode(offBoardCandidateSnapshot)
    }
    expectThrows("snapshot save rejects off-board cached candidate") {
      try QixiSnapshotStore.save(offBoardCandidateSnapshot)
    }
    let offBoardCandidateDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(offBoardCandidateSnapshot))
    expect(offBoardCandidateDecoded == nil, "snapshot decode rejects off-board cached candidate")

    let duplicateCandidateSnapshot = snapshotWithMutatedCache(original) { cache in
      cache.candidates[1].x = cache.candidates[0].x
      cache.candidates[1].y = cache.candidates[0].y
    }
    expectThrows("snapshot encode rejects duplicate cached candidate") {
      _ = try QixiSnapshotStore.encode(duplicateCandidateSnapshot)
    }
    let duplicateCandidateDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(duplicateCandidateSnapshot))
    expect(duplicateCandidateDecoded == nil, "snapshot decode rejects duplicate cached candidate")

    let invalidTerritorySnapshot = snapshotWithMutatedCache(original) { cache in
      cache.territory[0].ownership = 1.2
    }
    expectThrows("snapshot encode rejects invalid cached territory ownership") {
      _ = try QixiSnapshotStore.encode(invalidTerritorySnapshot)
    }
    let invalidTerritoryDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(invalidTerritorySnapshot))
    expect(invalidTerritoryDecoded == nil, "snapshot decode rejects invalid cached territory ownership")

    let mismatchedCacheKeySnapshot = snapshotWithMutatedCache(original) { cache in
      cache.positionKey = "different-position-key"
    }
    expectThrows("snapshot encode rejects mismatched cached position key") {
      _ = try QixiSnapshotStore.encode(mismatchedCacheKeySnapshot)
    }
    let mismatchedCacheKeyDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(mismatchedCacheKeySnapshot))
    expect(mismatchedCacheKeyDecoded == nil, "snapshot decode rejects mismatched cached position key")

    var wrongEngineCacheKeySnapshot = original
    let originalEngineKey = original.selectedEngine.rawValue
    let originalRootMoves = Array(original.mainLine.prefix(original.currentPly))
    let wrongEngineCacheKey = QixiPositionIdentity.cacheKey(
      engine: .b6,
      moves: originalRootMoves,
      komi: original.komi,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    wrongEngineCacheKeySnapshot.analysisByEngine[originalEngineKey] = [
      wrongEngineCacheKey: cachedAnalysis(
        savedAt: original.savedAt,
        positionKey: wrongEngineCacheKey,
        winrate: 0.49,
        scoreMean: -0.5
      )
    ]
    expectThrows("snapshot encode rejects wrong-engine analysis cache key") {
      _ = try QixiSnapshotStore.encode(wrongEngineCacheKeySnapshot)
    }
    let wrongEngineCacheKeyDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(wrongEngineCacheKeySnapshot))
    expect(wrongEngineCacheKeyDecoded == nil, "snapshot decode rejects wrong-engine analysis cache key")

    var malformedSemanticCacheKeySnapshot = original
    let malformedSemanticCacheKey = "\(originalEngineKey)|garbage"
    malformedSemanticCacheKeySnapshot.analysisByEngine[originalEngineKey] = [
      malformedSemanticCacheKey: cachedAnalysis(
        savedAt: original.savedAt,
        positionKey: malformedSemanticCacheKey,
        winrate: 0.48,
        scoreMean: -0.75
      )
    ]
    expectThrows("snapshot encode rejects malformed semantic cache key") {
      _ = try QixiSnapshotStore.encode(malformedSemanticCacheKeySnapshot)
    }
    let malformedSemanticCacheKeyDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(malformedSemanticCacheKeySnapshot))
    expect(malformedSemanticCacheKeyDecoded == nil, "snapshot decode rejects malformed semantic cache key")

    let canonicalSemanticCacheKey = QixiPositionIdentity.cacheKey(
      engine: original.selectedEngine,
      moves: originalRootMoves,
      komi: original.komi,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    let leadingZeroBitsCacheKey = canonicalSemanticCacheKey.replacingOccurrences(
      of: "|rootNoiseBits:0|history:",
      with: "|rootNoiseBits:00|history:"
    )
    expect(leadingZeroBitsCacheKey != canonicalSemanticCacheKey, "semantic cache key helper changed root-noise bits")
    let malformedLeadingZeroBitsSnapshot = snapshotWithReplacedCacheKey(original, cacheKey: leadingZeroBitsCacheKey)
    expectThrows("snapshot encode rejects leading-zero semantic cache bit fields") {
      _ = try QixiSnapshotStore.encode(malformedLeadingZeroBitsSnapshot)
    }
    let malformedLeadingZeroBitsDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(malformedLeadingZeroBitsSnapshot))
    expect(malformedLeadingZeroBitsDecoded == nil, "snapshot decode rejects leading-zero semantic cache bit fields")

    let overlongBitsCacheKey = canonicalSemanticCacheKey.replacingOccurrences(
      of: "|rootNoiseBits:0|history:",
      with: "|rootNoiseBits:10000000000000000|history:"
    )
    expect(overlongBitsCacheKey != canonicalSemanticCacheKey, "semantic cache key helper changed root-noise bits to an overlong field")
    let malformedOverlongBitsSnapshot = snapshotWithReplacedCacheKey(original, cacheKey: overlongBitsCacheKey)
    expectThrows("snapshot encode rejects overlong semantic cache bit fields") {
      _ = try QixiSnapshotStore.encode(malformedOverlongBitsSnapshot)
    }
    let malformedOverlongBitsDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(malformedOverlongBitsSnapshot))
    expect(malformedOverlongBitsDecoded == nil, "snapshot decode rejects overlong semantic cache bit fields")

    let nonfiniteKomiCacheKey = QixiPositionIdentity.cacheKey(
      engine: original.selectedEngine,
      moves: originalRootMoves,
      komi: Double.infinity,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    let nonfiniteKomiSemanticSnapshot = snapshotWithReplacedCacheKey(original, cacheKey: nonfiniteKomiCacheKey)
    expectThrows("snapshot encode rejects nonfinite semantic cache komi bits") {
      _ = try QixiSnapshotStore.encode(nonfiniteKomiSemanticSnapshot)
    }
    let nonfiniteKomiSemanticDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(nonfiniteKomiSemanticSnapshot))
    expect(nonfiniteKomiSemanticDecoded == nil, "snapshot decode rejects nonfinite semantic cache komi bits")

    let outOfRangeKomiCacheKey = QixiPositionIdentity.cacheKey(
      engine: original.selectedEngine,
      moves: originalRootMoves,
      komi: QixiAnalysisLimits.maxKomi + 0.5,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    let outOfRangeKomiSemanticSnapshot = snapshotWithReplacedCacheKey(original, cacheKey: outOfRangeKomiCacheKey)
    expectThrows("snapshot encode rejects out-of-range semantic cache komi bits") {
      _ = try QixiSnapshotStore.encode(outOfRangeKomiSemanticSnapshot)
    }
    let outOfRangeKomiSemanticDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(outOfRangeKomiSemanticSnapshot))
    expect(outOfRangeKomiSemanticDecoded == nil, "snapshot decode rejects out-of-range semantic cache komi bits")

    let negativeRootNoiseCacheKey = QixiPositionIdentity.cacheKey(
      engine: original.selectedEngine,
      moves: originalRootMoves,
      komi: original.komi,
      rootNoise: -0.01
    )
    let negativeRootNoiseSemanticSnapshot = snapshotWithReplacedCacheKey(original, cacheKey: negativeRootNoiseCacheKey)
    expectThrows("snapshot encode rejects negative semantic cache root-noise bits") {
      _ = try QixiSnapshotStore.encode(negativeRootNoiseSemanticSnapshot)
    }
    let negativeRootNoiseSemanticDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(negativeRootNoiseSemanticSnapshot))
    expect(negativeRootNoiseSemanticDecoded == nil, "snapshot decode rejects negative semantic cache root-noise bits")

    let illegalHistoryCacheKey = QixiPositionIdentity.cacheKey(
      engine: original.selectedEngine,
      moves: [
        BoardMove(color: .black, x: 3, y: 3),
        BoardMove(color: .white, x: 3, y: 3)
      ],
      komi: original.komi,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    let illegalHistorySemanticSnapshot = snapshotWithReplacedCacheKey(original, cacheKey: illegalHistoryCacheKey)
    expectThrows("snapshot encode rejects illegal semantic cache history") {
      _ = try QixiSnapshotStore.encode(illegalHistorySemanticSnapshot)
    }
    let illegalHistorySemanticDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(illegalHistorySemanticSnapshot))
    expect(illegalHistorySemanticDecoded == nil, "snapshot decode rejects illegal semantic cache history")

    var unknownEngineCacheSnapshot = original
    unknownEngineCacheSnapshot.analysisByEngine["mystery"] = unknownEngineCacheSnapshot.analysisByEngine[original.selectedEngine.rawValue]
    expectThrows("snapshot encode rejects unknown analysis cache engine") {
      _ = try QixiSnapshotStore.encode(unknownEngineCacheSnapshot)
    }
    let unknownEngineCacheDecoded = try QixiSnapshotStore.decode(try rawSnapshotData(unknownEngineCacheSnapshot))
    expect(unknownEngineCacheDecoded == nil, "snapshot decode rejects unknown analysis cache engine")

    var sameRestorableState = original
    sameRestorableState.savedAt = baseDate.addingTimeInterval(30)
    sameRestorableState.saveReason = "sameStateDifferentSaveMetadata"
    expect(
      sameRestorableState != original,
      "top-level save metadata participates in full snapshot equality"
    )
    expect(
      sameRestorableState.hasSameRestorableState(as: original),
      "restorable snapshot comparison ignores only top-level save metadata"
    )
    var changedRestorableState = sameRestorableState
    changedRestorableState.currentPly = 1
    expect(
      !changedRestorableState.hasSameRestorableState(as: original),
      "restorable snapshot comparison detects user-visible state changes"
    )

    var json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    json["schemaVersion"] = QixiAppSnapshot.currentSchemaVersion + 100
    let incompatible = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let incompatibleDecoded = try QixiSnapshotStore.decode(incompatible)
    expect(incompatibleDecoded == nil, "future schema snapshot must not be loaded as current state")

    try QixiSnapshotStore.save(original)
    expect(QixiSnapshotStore.load() == original, "local snapshot save/load round-trip")
    expect(
      FileManager.default.fileExists(atPath: QixiSnapshotStore.backupSnapshotURL.path),
      "local snapshot save writes a backup snapshot"
    )
    let savedOriginalData = try Data(contentsOf: QixiSnapshotStore.snapshotURL)
    var metadataOnlySnapshot = original
    metadataOnlySnapshot.savedAt = baseDate.addingTimeInterval(30)
    metadataOnlySnapshot.saveReason = "metadataOnlySave"
    let metadataOnlyDidWrite = try QixiSnapshotStore.saveIfRestorableStateChanged(metadataOnlySnapshot)
    expect(!metadataOnlyDidWrite, "saveIfRestorableStateChanged skips metadata-only snapshots")
    let afterMetadataOnlySaveData = try Data(contentsOf: QixiSnapshotStore.snapshotURL)
    expect(
      afterMetadataOnlySaveData == savedOriginalData,
      "metadata-only launch-ready save does not rewrite the autosave file"
    )
    try Data("{not-json".utf8).write(to: QixiSnapshotStore.snapshotURL, options: [.atomic])
    let primaryRepairDidWrite = try QixiSnapshotStore.saveIfRestorableStateChanged(metadataOnlySnapshot)
    expect(
      primaryRepairDidWrite,
      "saveIfRestorableStateChanged repairs an invalid primary autosave even when backup is equivalent"
    )
    expect(
      QixiSnapshotStore.load() == metadataOnlySnapshot,
      "repaired primary autosave loads after metadata-only repair write"
    )
    try QixiSnapshotStore.save(original)
    var changedRestorableSnapshot = original
    changedRestorableSnapshot.savedAt = baseDate.addingTimeInterval(45)
    changedRestorableSnapshot.saveReason = "changedRestorableSave"
    changedRestorableSnapshot.currentPly = original.currentPly + 1
    let changedRestorableDidWrite = try QixiSnapshotStore.saveIfRestorableStateChanged(changedRestorableSnapshot)
    expect(changedRestorableDidWrite, "saveIfRestorableStateChanged writes user-visible snapshot changes")
    expect(
      QixiSnapshotStore.load() == changedRestorableSnapshot,
      "changed restorable snapshot is persisted after saveIfRestorableStateChanged"
    )
    try QixiSnapshotStore.save(original)
    try Data("{not-json".utf8).write(to: QixiSnapshotStore.snapshotURL, options: [.atomic])
    expect(QixiSnapshotStore.load() == original, "corrupted primary snapshot falls back to backup")
    try QixiSnapshotStore.save(original)
    try duplicateTopLevelSnapshotData.write(to: QixiSnapshotStore.snapshotURL, options: [.atomic])
    expect(QixiSnapshotStore.load() == original, "duplicate-key primary snapshot falls back to backup")
    try QixiSnapshotStore.save(original)
    var futurePrimaryJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    futurePrimaryJSON["schemaVersion"] = QixiAppSnapshot.currentSchemaVersion + 100
    let futurePrimary = try JSONSerialization.data(withJSONObject: futurePrimaryJSON, options: [.sortedKeys])
    try futurePrimary.write(to: QixiSnapshotStore.snapshotURL, options: [.atomic])
    expect(QixiSnapshotStore.load() == original, "future primary snapshot schema falls back to backup")
    try QixiSnapshotStore.save(original)
    let newerBackup = snapshot(
      savedAt: baseDate.addingTimeInterval(90),
      reason: "newerBackup",
      currentPly: 3,
      engine: .b28nbt,
      winrate: 0.71,
      scoreMean: 6.5
    )
    try QixiSnapshotStore.encode(newerBackup).write(to: QixiSnapshotStore.backupSnapshotURL, options: [.atomic])
    expect(QixiSnapshotStore.load() == newerBackup, "local snapshot restore chooses the newest valid backup over an older valid primary")
    try QixiSnapshotStore.save(original)
    try QixiLifecycleTombstoneStore.mark(
      snapshot: original,
      reason: "didEnterBackground",
      engineTombstoneFilename: QixiEngineTombstoneStore.tombstoneFilename,
      markedAt: baseDate.addingTimeInterval(5)
    )
    guard let tombstone = QixiLifecycleTombstoneStore.load() else {
      fail("lifecycle tombstone should load after mark")
    }
    expect(tombstone.reason == "didEnterBackground", "lifecycle tombstone records the trigger reason")
    expect(tombstone.snapshotSavedAt == original.savedAt, "lifecycle tombstone references the saved snapshot timestamp")
    expect(tombstone.snapshotFilename == QixiSnapshotStore.snapshotFilename, "lifecycle tombstone names the autosave file")
    expect(tombstone.selectedEngine == original.selectedEngine, "lifecycle tombstone records selected engine")
    expect(tombstone.currentPly == original.currentPly, "lifecycle tombstone records current ply")
    expect(tombstone.mainLineCount == original.mainLine.count, "lifecycle tombstone records main-line length")
    expect(
      tombstone.engineTombstoneFilename == QixiEngineTombstoneStore.tombstoneFilename,
      "lifecycle tombstone records the native engine tombstone filename when available"
    )
    let runtimeDiagnostic = QixiRuntimeDiagnostic(
      recordedAt: baseDate.addingTimeInterval(6),
      event: "analysisFailed",
      success: false,
      selectedEngine: .b6,
      analysisRuntime: "httpBridge",
      backendBaseURL: "http://192.168.3.61:8765",
      message: "URLSession diagnostic"
    )
    try QixiRuntimeDiagnosticStore.record(runtimeDiagnostic)
    let runtimeDiagnosticData = try Data(contentsOf: QixiRuntimeDiagnosticStore.diagnosticURL)
    let runtimeDiagnosticPayload = try JSONSerialization.jsonObject(with: runtimeDiagnosticData) as? [String: Any] ?? [:]
    expect(
      runtimeDiagnosticPayload["schemaVersion"] as? Int == QixiRuntimeDiagnostic.currentSchemaVersion,
      "runtime diagnostic records the current schema version"
    )
    expect(
      runtimeDiagnosticPayload["event"] as? String == "analysisFailed",
      "runtime diagnostic records the latest event"
    )
    let diagnosticDecoder = JSONDecoder()
    diagnosticDecoder.dateDecodingStrategy = .iso8601
    let decodedRuntimeDiagnostic = try diagnosticDecoder.decode(QixiRuntimeDiagnostic.self, from: runtimeDiagnosticData)
    expect(decodedRuntimeDiagnostic == runtimeDiagnostic, "runtime diagnostic save preserves bridge failure context")
    try writeSparseFile(
      at: QixiLifecycleTombstoneStore.tombstoneURL,
      byteCount: UInt64(QixiLifecycleTombstoneStore.maxTombstoneBytes + 1)
    )
    expect(QixiLifecycleTombstoneStore.load() == nil, "oversized lifecycle tombstone URL is rejected before loading")
    let lifecycleTombstoneTargetURL = snapshotsRoot.appendingPathComponent("lifecycle-tombstone-target.qixi-state.json")
    try QixiLifecycleTombstoneStore.encode(tombstone).write(to: lifecycleTombstoneTargetURL, options: [.atomic])
    try? FileManager.default.removeItem(at: QixiLifecycleTombstoneStore.tombstoneURL)
    try FileManager.default.createSymbolicLink(
      at: QixiLifecycleTombstoneStore.tombstoneURL,
      withDestinationURL: lifecycleTombstoneTargetURL
    )
    expect(QixiLifecycleTombstoneStore.load() == nil, "lifecycle tombstone URL rejects symbolic-link files before loading")
    expectThrowsContaining(
      "lifecycle tombstone mark rejects symbolic-link paths",
      "symbolic links"
    ) {
      try QixiLifecycleTombstoneStore.mark(
        snapshot: original,
        reason: "didEnterBackground",
        engineTombstoneFilename: QixiEngineTombstoneStore.tombstoneFilename,
        markedAt: baseDate.addingTimeInterval(5)
      )
    }
    try? FileManager.default.removeItem(at: QixiLifecycleTombstoneStore.tombstoneURL)
    try? FileManager.default.removeItem(at: lifecycleTombstoneTargetURL)
    try QixiLifecycleTombstoneStore.mark(
      snapshot: original,
      reason: "didEnterBackground",
      engineTombstoneFilename: QixiEngineTombstoneStore.tombstoneFilename,
      markedAt: baseDate.addingTimeInterval(5)
    )
    expect(
      QixiEngineTombstoneStore.tombstoneURL.lastPathComponent == QixiEngineTombstoneStore.tombstoneFilename,
      "native engine tombstone store resolves the engine tombstone filename"
    )
    try QixiEngineTombstoneStore.markExported(
      engine: .b6,
      reason: "didEnterBackground",
      exportedAt: baseDate.addingTimeInterval(8)
    )
    guard let exportAudit = QixiEngineTombstoneStore.loadExportAudit() else {
      fail("native engine tombstone export audit should load after mark")
    }
    expect(
      exportAudit.exportedAt == baseDate.addingTimeInterval(8),
      "native engine tombstone export audit records export timestamp"
    )
    expect(
      exportAudit.tombstoneFilename == QixiEngineTombstoneStore.tombstoneFilename,
      "native engine tombstone export audit records the exported tombstone filename"
    )
    expect(exportAudit.engine == .b6, "native engine tombstone export audit records the exported engine")
    expect(exportAudit.reason == "didEnterBackground", "native engine tombstone export audit records lifecycle reason")
    expect(
      QixiEngineTombstoneStore.exportAuditURL.lastPathComponent == QixiEngineTombstoneStore.exportAuditFilename,
      "native engine tombstone store resolves the export audit filename"
    )
    var exportAuditJSON = try JSONSerialization.jsonObject(
      with: try QixiEngineTombstoneStore.encode(exportAudit)
    ) as? [String: Any] ?? [:]
    exportAuditJSON["schemaVersion"] = QixiEngineTombstoneExportAudit.currentSchemaVersion + 100
    let incompatibleExportAudit = try JSONSerialization.data(
      withJSONObject: exportAuditJSON,
      options: [.sortedKeys]
    )
    let incompatibleExportAuditDecoded = try QixiEngineTombstoneStore.decodeExportAudit(incompatibleExportAudit)
    expect(incompatibleExportAuditDecoded == nil, "future native engine export audit schema must not load")
    try writeSparseFile(
      at: QixiEngineTombstoneStore.exportAuditURL,
      byteCount: UInt64(QixiEngineTombstoneStore.maxAuditBytes + 1)
    )
    expect(QixiEngineTombstoneStore.loadExportAudit() == nil, "oversized native engine export audit URL is rejected before loading")
    let engineExportAuditTargetURL = snapshotsRoot.appendingPathComponent("native-engine-tombstone.export.target.json")
    try QixiEngineTombstoneStore.encode(exportAudit).write(to: engineExportAuditTargetURL, options: [.atomic])
    try? FileManager.default.removeItem(at: QixiEngineTombstoneStore.exportAuditURL)
    try FileManager.default.createSymbolicLink(
      at: QixiEngineTombstoneStore.exportAuditURL,
      withDestinationURL: engineExportAuditTargetURL
    )
    expect(QixiEngineTombstoneStore.loadExportAudit() == nil, "native engine export audit URL rejects symbolic-link files before loading")
    expectThrowsContaining(
      "native engine export audit mark rejects symbolic-link paths",
      "symbolic links"
    ) {
      try QixiEngineTombstoneStore.markExported(
        engine: .b6,
        reason: "didEnterBackground",
        exportedAt: baseDate.addingTimeInterval(8)
      )
    }
    try? FileManager.default.removeItem(at: QixiEngineTombstoneStore.exportAuditURL)
    try? FileManager.default.removeItem(at: engineExportAuditTargetURL)
    try QixiEngineTombstoneStore.markExported(
      engine: .b6,
      reason: "didEnterBackground",
      exportedAt: baseDate.addingTimeInterval(8)
    )
    try QixiEngineTombstoneStore.markRestored(engine: .b18nbt, restoredAt: baseDate.addingTimeInterval(10))
    guard let restoreAudit = QixiEngineTombstoneStore.loadRestoreAudit() else {
      fail("native engine tombstone restore audit should load after mark")
    }
    expect(
      restoreAudit.restoredAt == baseDate.addingTimeInterval(10),
      "native engine tombstone restore audit records restore timestamp"
    )
    expect(
      restoreAudit.tombstoneFilename == QixiEngineTombstoneStore.tombstoneFilename,
      "native engine tombstone restore audit records the restored tombstone filename"
    )
    expect(
      restoreAudit.engine == .b18nbt,
      "native engine tombstone restore audit records the restored engine"
    )
    expect(
      QixiEngineTombstoneStore.restoreAuditURL.lastPathComponent == QixiEngineTombstoneStore.restoreAuditFilename,
      "native engine tombstone store resolves the restore audit filename"
    )
    try writeSparseFile(
      at: QixiEngineTombstoneStore.restoreAuditURL,
      byteCount: UInt64(QixiEngineTombstoneStore.maxAuditBytes + 1)
    )
    expect(QixiEngineTombstoneStore.loadRestoreAudit() == nil, "oversized native engine restore audit URL is rejected before loading")
    let engineRestoreAuditTargetURL = snapshotsRoot.appendingPathComponent("native-engine-tombstone.restore.target.json")
    try QixiEngineTombstoneStore.encode(restoreAudit).write(to: engineRestoreAuditTargetURL, options: [.atomic])
    try? FileManager.default.removeItem(at: QixiEngineTombstoneStore.restoreAuditURL)
    try FileManager.default.createSymbolicLink(
      at: QixiEngineTombstoneStore.restoreAuditURL,
      withDestinationURL: engineRestoreAuditTargetURL
    )
    expect(QixiEngineTombstoneStore.loadRestoreAudit() == nil, "native engine restore audit URL rejects symbolic-link files before loading")
    expectThrowsContaining(
      "native engine restore audit mark rejects symbolic-link paths",
      "symbolic links"
    ) {
      try QixiEngineTombstoneStore.markRestored(engine: .b18nbt, restoredAt: baseDate.addingTimeInterval(10))
    }
    try? FileManager.default.removeItem(at: QixiEngineTombstoneStore.restoreAuditURL)
    try? FileManager.default.removeItem(at: engineRestoreAuditTargetURL)
    var restoreAuditJSON = try JSONSerialization.jsonObject(
      with: try QixiEngineTombstoneStore.encode(restoreAudit)
    ) as? [String: Any] ?? [:]
    restoreAuditJSON["schemaVersion"] = QixiEngineTombstoneRestoreAudit.currentSchemaVersion + 100
    let incompatibleRestoreAudit = try JSONSerialization.data(
      withJSONObject: restoreAuditJSON,
      options: [.sortedKeys]
    )
    let incompatibleRestoreAuditDecoded = try QixiEngineTombstoneStore.decode(incompatibleRestoreAudit)
    expect(incompatibleRestoreAuditDecoded == nil, "future native engine restore audit schema must not load")

    let cachedAnalysis = firstCachedAnalysis(in: original)
    let realDeviceRunId = "00000000-0000-4000-8000-000000000001"
    let realDeviceMeasurements = QixiRealDeviceEvidence.Measurements(
      launch: QixiRealDeviceEvidence.Launch(coldLaunchMs: 900, visualReadyMs: 1400),
      memory: QixiRealDeviceEvidence.Memory(peakRSSMB: 620, postAnalysisRSSMB: 590),
      framePacing: QixiRealDeviceEvidence.FramePacing(
        targetRefreshHz: 120,
        observedRefreshHz: 118,
        droppedFramePercent: 1.2
      )
    )
    func iso8601String(_ date: Date) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.string(from: date)
    }
    func performanceArtifactData(
      measurements: QixiRealDeviceEvidence.Measurements,
      recordedAt: Date,
      runId: String
    ) throws -> Data {
      let payload: [String: Any] = [
        "schemaVersion": 1,
        "kind": "qixi-real-device-performance",
        "source": "instruments",
        "runId": runId,
        "recordedAt": iso8601String(recordedAt),
        "measurements": [
          "launch": [
            "coldLaunchMs": measurements.launch.coldLaunchMs,
            "visualReadyMs": measurements.launch.visualReadyMs
          ],
          "memory": [
            "peakRSSMB": measurements.memory.peakRSSMB,
            "postAnalysisRSSMB": measurements.memory.postAnalysisRSSMB
          ],
          "framePacing": [
            "targetRefreshHz": measurements.framePacing.targetRefreshHz,
            "observedRefreshHz": measurements.framePacing.observedRefreshHz,
            "droppedFramePercent": measurements.framePacing.droppedFramePercent
          ]
        ]
      ]
      var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      data.append(0x0A)
      return data
    }
    func deviceLogArtifactData(evidence: QixiRealDeviceEvidence) throws -> Data {
      try QixiRealDeviceEvidenceStore.deviceLogArtifactData(for: evidence)
    }
    func fingerprintedArtifact(kind: String, path: String) throws -> QixiRealDeviceEvidence.Artifact {
      try QixiRealDeviceEvidenceStore.fingerprintedArtifact(
        kind: kind,
        path: path,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    func evidenceByRefreshingArtifact(
      _ evidence: QixiRealDeviceEvidence,
      kind: String,
      path: String
    ) throws -> QixiRealDeviceEvidence {
      var refreshed = evidence
      guard let index = refreshed.artifacts.firstIndex(where: { $0.kind == kind }) else {
        fail("missing real-device evidence artifact kind \(kind)")
      }
      refreshed.artifacts[index] = try fingerprintedArtifact(kind: kind, path: path)
      return refreshed
    }
    func evidenceByReplacingArtifact(
      _ evidence: QixiRealDeviceEvidence,
      kind: String,
      path: String,
      byteCount: UInt64,
      sha256HexDigest: String = String(repeating: "0", count: 64)
    ) -> QixiRealDeviceEvidence {
      var replaced = evidence
      guard let index = replaced.artifacts.firstIndex(where: { $0.kind == kind }) else {
        fail("missing real-device evidence artifact kind \(kind)")
      }
      replaced.artifacts[index] = QixiRealDeviceEvidence.Artifact(
        kind: kind,
        path: path,
        byteCount: byteCount,
        sha256HexDigest: sha256HexDigest
      )
      return replaced
    }
    let artifactFiles = [
      ("screenshot", "real-device-ipad-main.png"),
      ("performance", "real-device-instruments.json"),
      ("device-log", "real-device.log")
    ]
    let ipadLandscapePNG = try pngWithGrid(width: 1200, height: 800)
    let ipadBlankLandscapePNG = try pngWithGrid(width: 1200, height: 800, drawGrid: false)
    let ipadPortraitPNG = try pngWithGrid(width: 800, height: 1200)
    let tinyLandscapePNG = try pngWithGrid(width: 640, height: 360)
    for (kind, filename) in artifactFiles {
      let artifactURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(filename)
      if kind == "screenshot" {
        try ipadLandscapePNG.write(to: artifactURL, options: [.atomic])
      } else if kind == "performance" {
        try performanceArtifactData(
          measurements: realDeviceMeasurements,
          recordedAt: baseDate.addingTimeInterval(12),
          runId: realDeviceRunId
        ).write(to: artifactURL, options: [.atomic])
      } else {
        try Data("placeholder device log\n".utf8).write(to: artifactURL, options: [.atomic])
      }
    }
    var realDeviceEvidence = QixiRealDeviceEvidence(
      runId: realDeviceRunId,
      recordedAt: baseDate.addingTimeInterval(12),
      device: QixiRealDeviceEvidence.Device(
        idiom: "iPad",
        model: "iPad Pro 13-inch (M5)",
        osVersion: "iPadOS 26.5",
        simulator: false
      ),
      app: QixiRealDeviceEvidence.App(
        bundleIdentifier: "com.qixi.localanalysis",
        version: "1.0",
        build: "1",
        analysisRuntime: "httpBridge",
        executableSHA256HexDigest: String(repeating: "a", count: 64)
      ),
      backend: QixiRealDeviceEvidence.Backend(
        url: "http://192.168.1.23:8765",
        status: QixiRealDeviceEvidence.BackendStatus(
          engine: "katago-metal-mux:\(original.selectedEngine.rawValue)",
          engineId: original.selectedEngine.rawValue,
          state: "running",
          running: true,
          paused: false
        )
      ),
      analysis: QixiRealDeviceEvidenceStore.analysisEvidence(
        engine: original.selectedEngine,
        cachedAnalysis: cachedAnalysis
      ),
      measurements: realDeviceMeasurements,
      lifecycle: QixiRealDeviceEvidence.Lifecycle(
        backgroundedSeconds: 30,
        autosaveWritten: true,
        tombstoneWritten: true,
        restoredLatestState: true
      ),
      features: QixiRealDeviceEvidence.Features(
        cameraRecognitionTested: true,
        iCloudSyncTested: true,
        modelImportTested: true
      ),
      artifacts: artifactFiles.map { kind, filename in
        QixiRealDeviceEvidence.Artifact(
          kind: kind,
          path: filename,
          byteCount: 0,
          sha256HexDigest: String(repeating: "0", count: 64)
        )
      }
    )
    let deviceLogArtifactURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("real-device.log")
    let generatedDeviceLogArtifact = try QixiRealDeviceEvidenceStore.writeDeviceLogArtifact(
      for: realDeviceEvidence,
      path: "real-device.log",
      evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
    )
    expect(
      generatedDeviceLogArtifact.kind == "device-log" &&
        generatedDeviceLogArtifact.path == "real-device.log" &&
        generatedDeviceLogArtifact.byteCount > 0,
      "real-device evidence store auto-writes and fingerprints the matching device-log artifact"
    )
    let generatedDeviceLogJSON = try JSONSerialization.jsonObject(
      with: try Data(contentsOf: deviceLogArtifactURL)
    ) as? [String: Any] ?? [:]
    expect(
      generatedDeviceLogJSON["kind"] as? String == "qixi-real-device-log",
      "auto-written real-device device-log artifact is structured release evidence JSON"
    )
    realDeviceEvidence.artifacts = try artifactFiles.map { kind, filename in
      if kind == "device-log" { return generatedDeviceLogArtifact }
      return try fingerprintedArtifact(kind: kind, path: filename)
    }
    try QixiRealDeviceEvidenceStore.save(realDeviceEvidence)
    guard let loadedRealDeviceEvidence = QixiRealDeviceEvidenceStore.load() else {
      fail("real-device evidence should load after save")
    }
    expect(
      loadedRealDeviceEvidence == realDeviceEvidence,
      "real-device evidence save/load preserves the release evidence payload"
    )
    let realDeviceEvidenceJSON = try JSONSerialization.jsonObject(
      with: try Data(contentsOf: QixiRealDeviceEvidenceStore.evidenceURL)
    ) as? [String: Any] ?? [:]
    expect(
      realDeviceEvidenceJSON["kind"] as? String == "qixi-real-device-evidence",
      "real-device evidence JSON uses the release preflight kind"
    )
    expect(
      realDeviceEvidenceJSON["schemaVersion"] as? Int == QixiRealDeviceEvidence.currentSchemaVersion,
      "real-device evidence JSON uses the current schema"
    )
    expect(
      realDeviceEvidenceJSON["runId"] as? String == realDeviceRunId,
      "real-device evidence JSON carries the run identity"
    )
    try runRealDeviceEvidencePreflight(
      evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL,
      backendURL: "http://192.168.1.23:8765"
    )

    let validRealDeviceEvidenceData = try QixiRealDeviceEvidenceStore.encode(
      realDeviceEvidence,
      evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
    )
    try writeSparseFile(
      at: QixiRealDeviceEvidenceStore.evidenceURL,
      byteCount: UInt64(QixiRealDeviceEvidenceStore.maxEvidenceBytes + 1)
    )
    expect(QixiRealDeviceEvidenceStore.load() == nil, "oversized real-device evidence URL is rejected before loading")
    try validRealDeviceEvidenceData.write(to: QixiRealDeviceEvidenceStore.evidenceURL, options: [.atomic])
    let linkedRealDeviceEvidenceURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(
      "linked-real-device-evidence.qixi-release.json"
    )
    try? FileManager.default.removeItem(at: linkedRealDeviceEvidenceURL)
    try FileManager.default.createSymbolicLink(
      at: linkedRealDeviceEvidenceURL,
      withDestinationURL: QixiRealDeviceEvidenceStore.evidenceURL
    )
    expect(
      QixiRealDeviceEvidenceStore.load(from: linkedRealDeviceEvidenceURL) == nil,
      "real-device evidence URL rejects symbolic-link evidence files before loading"
    )
    expectThrowsContaining(
      "real-device evidence save rejects symbolic-link evidence paths",
      "symbolic links"
    ) {
      try QixiRealDeviceEvidenceStore.save(realDeviceEvidence, to: linkedRealDeviceEvidenceURL)
    }
    try? FileManager.default.removeItem(at: linkedRealDeviceEvidenceURL)
    let linkedRealDeviceEvidenceDirectory = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(
      "linked-real-device-evidence-directory",
      isDirectory: true
    )
    let linkedRealDeviceEvidenceDirectoryTarget = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(
      "linked-real-device-evidence-directory-target",
      isDirectory: true
    )
    try? FileManager.default.removeItem(at: linkedRealDeviceEvidenceDirectory)
    try? FileManager.default.removeItem(at: linkedRealDeviceEvidenceDirectoryTarget)
    try FileManager.default.createDirectory(at: linkedRealDeviceEvidenceDirectoryTarget, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedRealDeviceEvidenceDirectory,
      withDestinationURL: linkedRealDeviceEvidenceDirectoryTarget
    )
    expectThrowsContaining(
      "real-device evidence save rejects symbolic-link evidence directories",
      "symbolic links"
    ) {
      try QixiRealDeviceEvidenceStore.save(
        realDeviceEvidence,
        to: linkedRealDeviceEvidenceDirectory.appendingPathComponent(QixiRealDeviceEvidenceStore.evidenceFilename)
      )
    }
    try? FileManager.default.removeItem(at: linkedRealDeviceEvidenceDirectory)
    try? FileManager.default.removeItem(at: linkedRealDeviceEvidenceDirectoryTarget)
    expectThrowsContaining(
      "real-device evidence output rejects export audit filename",
      "export audit filename"
    ) {
      try QixiRealDeviceEvidenceStore.save(realDeviceEvidence, to: QixiRealDeviceEvidenceStore.exportAuditURL)
    }
    let directoryEvidenceOutputURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(
      "real-device-evidence-directory-output",
      isDirectory: true
    )
    try? FileManager.default.removeItem(at: directoryEvidenceOutputURL)
    try FileManager.default.createDirectory(at: directoryEvidenceOutputURL, withIntermediateDirectories: true)
    expectThrowsContaining(
      "real-device evidence output rejects directory paths",
      "must name a JSON file"
    ) {
      try QixiRealDeviceEvidenceStore.save(realDeviceEvidence, to: directoryEvidenceOutputURL)
    }
    try? FileManager.default.removeItem(at: directoryEvidenceOutputURL)
    expectThrowsContaining(
      "real-device evidence output rejects non-JSON paths",
      "must name a JSON file"
    ) {
      try QixiRealDeviceEvidenceStore.save(
        realDeviceEvidence,
        to: QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("real-device-evidence.txt")
      )
    }
    let duplicateTopLevelRealDeviceEvidenceData = dataByReplacingFirst(
      in: validRealDeviceEvidenceData,
      "\"schemaVersion\":\(QixiRealDeviceEvidence.currentSchemaVersion)",
      "\"schemaVersion\":\(QixiRealDeviceEvidence.currentSchemaVersion),\"schemaVersion\":\(QixiRealDeviceEvidence.currentSchemaVersion)"
    )
    expectThrows("real-device evidence decode rejects duplicate top-level JSON keys") {
      _ = try QixiRealDeviceEvidenceStore.decode(duplicateTopLevelRealDeviceEvidenceData)
    }
    let duplicateNestedRealDeviceEvidenceData = dataByReplacingFirst(
      in: validRealDeviceEvidenceData,
      "\"analysisRuntime\":\"httpBridge\"",
      "\"analysisRuntime\":\"httpBridge\",\"analysisRuntime\":\"httpBridge\""
    )
    expectThrows("real-device evidence decode rejects nested duplicate JSON keys") {
      _ = try QixiRealDeviceEvidenceStore.decode(duplicateNestedRealDeviceEvidenceData)
    }
    let nonStandardRealDeviceEvidenceData = dataByReplacingFirst(
      in: validRealDeviceEvidenceData,
      "\"simulator\":false",
      "\"simulator\":NaN"
    )
    expectThrows("real-device evidence decode rejects non-standard JSON constants") {
      _ = try QixiRealDeviceEvidenceStore.decode(nonStandardRealDeviceEvidenceData)
    }
    expectThrows("real-device evidence decode rejects non-object JSON documents") {
      _ = try QixiRealDeviceEvidenceStore.decode(Data("[]".utf8))
    }
    expectThrows("real-device evidence decode rejects oversized JSON documents before decoding") {
      _ = try QixiRealDeviceEvidenceStore.decode(
        Data(repeating: 0x20, count: QixiRealDeviceEvidenceStore.maxEvidenceBytes + 1)
      )
    }

    let exportAuditData = try QixiRealDeviceEvidenceStore.encode(
      QixiRealDeviceEvidenceExportAudit(
        recordedAt: baseDate.addingTimeInterval(12),
        status: "exported",
        evidenceFilename: QixiRealDeviceEvidenceStore.evidenceFilename,
        error: nil
      )
    )
    let duplicateExportAuditData = dataByReplacingFirst(
      in: exportAuditData,
      "\"status\":\"exported\"",
      "\"status\":\"exported\",\"status\":\"failed\""
    )
    expectThrows("real-device evidence export audit rejects duplicate JSON keys") {
      _ = try QixiRealDeviceEvidenceStore.decodeExportAudit(duplicateExportAuditData)
    }
    expectThrows("real-device evidence export audit rejects non-object JSON documents") {
      _ = try QixiRealDeviceEvidenceStore.decodeExportAudit(Data("[]".utf8))
    }
    expectThrows("real-device evidence export audit rejects oversized JSON documents before decoding") {
      _ = try QixiRealDeviceEvidenceStore.decodeExportAudit(
        Data(repeating: 0x20, count: QixiRealDeviceEvidenceStore.maxExportAuditBytes + 1)
      )
    }
    try writeSparseFile(
      at: QixiRealDeviceEvidenceStore.exportAuditURL,
      byteCount: UInt64(QixiRealDeviceEvidenceStore.maxExportAuditBytes + 1)
    )
    expect(QixiRealDeviceEvidenceStore.loadExportAudit() == nil, "oversized real-device evidence export audit URL is rejected before loading")
    try exportAuditData.write(to: QixiRealDeviceEvidenceStore.exportAuditURL, options: [.atomic])
    let linkedExportAuditTargetURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent(
      "real-device-evidence.export.target.json"
    )
    try exportAuditData.write(to: linkedExportAuditTargetURL, options: [.atomic])
    try? FileManager.default.removeItem(at: QixiRealDeviceEvidenceStore.exportAuditURL)
    try FileManager.default.createSymbolicLink(
      at: QixiRealDeviceEvidenceStore.exportAuditURL,
      withDestinationURL: linkedExportAuditTargetURL
    )
    expect(
      QixiRealDeviceEvidenceStore.loadExportAudit() == nil,
      "real-device evidence export audit URL rejects symbolic-link files before loading"
    )
    expectThrowsContaining(
      "real-device evidence export audit save rejects symbolic-link paths",
      "symbolic links"
    ) {
      try QixiRealDeviceEvidenceStore.markExported(
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL,
        recordedAt: baseDate.addingTimeInterval(12)
      )
    }
    try? FileManager.default.removeItem(at: QixiRealDeviceEvidenceStore.exportAuditURL)
    try? FileManager.default.removeItem(at: linkedExportAuditTargetURL)
    try exportAuditData.write(to: QixiRealDeviceEvidenceStore.exportAuditURL, options: [.atomic])
    let movedSnapshotsRoot = QixiSnapshotStore.snapshotsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("moved-snapshots-before-real-device-audit-directory-symlink", isDirectory: true)
    let linkedSnapshotsRootTarget = QixiSnapshotStore.snapshotsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("linked-snapshots-real-device-audit-target", isDirectory: true)
    try? FileManager.default.removeItem(at: movedSnapshotsRoot)
    try? FileManager.default.removeItem(at: linkedSnapshotsRootTarget)
    try FileManager.default.moveItem(at: QixiSnapshotStore.snapshotsDirectory, to: movedSnapshotsRoot)
    try FileManager.default.createDirectory(at: linkedSnapshotsRootTarget, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: QixiSnapshotStore.snapshotsDirectory,
      withDestinationURL: linkedSnapshotsRootTarget
    )
    expectThrowsContaining(
      "real-device evidence export audit save rejects symbolic-link directories",
      "symbolic links"
    ) {
      try QixiRealDeviceEvidenceStore.markExported(
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL,
        recordedAt: baseDate.addingTimeInterval(12)
      )
    }
    expect(
      !FileManager.default.fileExists(
        atPath: linkedSnapshotsRootTarget.appendingPathComponent(QixiRealDeviceEvidenceStore.exportAuditFilename).path
      ),
      "real-device evidence export audit does not write through symbolic-link directories"
    )
    try? FileManager.default.removeItem(at: QixiSnapshotStore.snapshotsDirectory)
    try? FileManager.default.removeItem(at: linkedSnapshotsRootTarget)
    try FileManager.default.moveItem(at: movedSnapshotsRoot, to: QixiSnapshotStore.snapshotsDirectory)

    let strictPerformanceArtifactURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("real-device-instruments.json")
    let validPerformanceArtifactData = try Data(contentsOf: strictPerformanceArtifactURL)
    let duplicatePerformanceArtifactData = dataByReplacingFirst(
      in: validPerformanceArtifactData,
      "\"runId\":\"\(realDeviceRunId)\"",
      "\"runId\":\"\(realDeviceRunId)\",\"runId\":\"\(realDeviceRunId)\""
    )
    try duplicatePerformanceArtifactData.write(to: strictPerformanceArtifactURL, options: [.atomic])
    let duplicatePerformanceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device performance artifact rejects duplicate JSON keys") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        duplicatePerformanceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try validPerformanceArtifactData.write(to: strictPerformanceArtifactURL, options: [.atomic])

    let nonStandardPerformanceArtifactData = dataByReplacingFirst(
      in: validPerformanceArtifactData,
      "\"observedRefreshHz\":118",
      "\"observedRefreshHz\":NaN"
    )
    try nonStandardPerformanceArtifactData.write(to: strictPerformanceArtifactURL, options: [.atomic])
    let nonStandardPerformanceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device performance artifact rejects non-standard JSON constants") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nonStandardPerformanceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try validPerformanceArtifactData.write(to: strictPerformanceArtifactURL, options: [.atomic])

    try writeSparseFile(
      at: strictPerformanceArtifactURL,
      byteCount: UInt64(QixiRealDeviceEvidenceStore.maxPerformanceArtifactBytes + 1)
    )
    let oversizedPerformanceByteCount = UInt64(QixiRealDeviceEvidenceStore.maxPerformanceArtifactBytes + 1)
    let oversizedPerformanceEvidence = evidenceByReplacingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json",
      byteCount: oversizedPerformanceByteCount
    )
    expectThrowsContaining(
      "real-device performance artifact rejects oversized JSON files before loading and before fingerprinting",
      "before fingerprinting"
    ) {
      _ = try QixiRealDeviceEvidenceStore.encode(
        oversizedPerformanceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try validPerformanceArtifactData.write(to: strictPerformanceArtifactURL, options: [.atomic])

    let validDeviceLogArtifactData = try deviceLogArtifactData(evidence: realDeviceEvidence)
    try validDeviceLogArtifactData.write(to: deviceLogArtifactURL, options: [.atomic])
    let duplicateDeviceLogArtifactData = dataByReplacingFirst(
      in: validDeviceLogArtifactData,
      "\"analysisRuntime\":\"httpBridge\"",
      "\"analysisRuntime\":\"httpBridge\",\"analysisRuntime\":\"httpBridge\""
    )
    try duplicateDeviceLogArtifactData.write(to: deviceLogArtifactURL, options: [.atomic])
    let duplicateDeviceLogEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device device-log artifact rejects duplicate JSON keys") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        duplicateDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try validDeviceLogArtifactData.write(to: deviceLogArtifactURL, options: [.atomic])

    try writeSparseFile(
      at: deviceLogArtifactURL,
      byteCount: UInt64(QixiRealDeviceEvidenceStore.maxDeviceLogArtifactBytes + 1)
    )
    let oversizedDeviceLogByteCount = UInt64(QixiRealDeviceEvidenceStore.maxDeviceLogArtifactBytes + 1)
    let oversizedDeviceLogEvidence = evidenceByReplacingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log",
      byteCount: oversizedDeviceLogByteCount
    )
    expectThrowsContaining(
      "real-device device-log artifact rejects oversized JSON files before loading and before fingerprinting",
      "before fingerprinting"
    ) {
      _ = try QixiRealDeviceEvidenceStore.encode(
        oversizedDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try validDeviceLogArtifactData.write(to: deviceLogArtifactURL, options: [.atomic])

    var futureRecordedAtEvidence = realDeviceEvidence
    futureRecordedAtEvidence.recordedAt = Date().addingTimeInterval(10 * 60)
    expectThrows("real-device evidence rejects future recordedAt values") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        futureRecordedAtEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var staleRecordedAtEvidence = realDeviceEvidence
    staleRecordedAtEvidence.recordedAt = baseDate.addingTimeInterval(-8 * 24 * 60 * 60)
    expectThrows("real-device evidence rejects stale recordedAt values") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        staleRecordedAtEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }

    var invalidRunIdEvidence = realDeviceEvidence
    invalidRunIdEvidence.runId = "not-a-run-id"
    expectThrows("real-device evidence rejects invalid runId values") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        invalidRunIdEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }

    var unsupportedArtifactEvidence = realDeviceEvidence
    unsupportedArtifactEvidence.artifacts.append(
      QixiRealDeviceEvidence.Artifact(
        kind: "trace",
        path: "real-device.log",
        byteCount: 1,
        sha256HexDigest: String(repeating: "0", count: 64)
      )
    )
    expectThrows("real-device evidence rejects unsupported artifact kinds") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        unsupportedArtifactEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var duplicatedArtifactEvidence = realDeviceEvidence
    duplicatedArtifactEvidence.artifacts.append(
      QixiRealDeviceEvidence.Artifact(
        kind: "screenshot",
        path: "real-device-ipad-main.png",
        byteCount: 1,
        sha256HexDigest: String(repeating: "0", count: 64)
      )
    )
    expectThrows("real-device evidence rejects duplicate artifact kinds") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        duplicatedArtifactEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    let screenshotArtifactURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("real-device-ipad-main.png")
    var absoluteArtifactPathEvidence = realDeviceEvidence
    absoluteArtifactPathEvidence.artifacts[0].path = screenshotArtifactURL.path
    expectThrows("real-device evidence rejects absolute artifact paths") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        absoluteArtifactPathEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var parentTraversalArtifactPathEvidence = realDeviceEvidence
    parentTraversalArtifactPathEvidence.artifacts[1].path = "../real-device-instruments.json"
    expectThrows("real-device evidence rejects parent-traversal artifact paths") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        parentTraversalArtifactPathEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var duplicatedArtifactPathEvidence = realDeviceEvidence
    duplicatedArtifactPathEvidence.artifacts[1].path = "real-device-ipad-main.png"
    expectThrows("real-device evidence rejects duplicate artifact paths") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        duplicatedArtifactPathEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var reservedEvidenceFilenameArtifactPath = realDeviceEvidence
    reservedEvidenceFilenameArtifactPath.artifacts[0].path = QixiRealDeviceEvidenceStore.evidenceFilename
    expectThrowsContaining(
      "real-device evidence rejects artifact paths using reserved evidence filenames",
      "reserved real-device evidence filenames"
    ) {
      _ = try QixiRealDeviceEvidenceStore.encode(
        reservedEvidenceFilenameArtifactPath,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var reservedExportAuditArtifactPath = realDeviceEvidence
    reservedExportAuditArtifactPath.artifacts[0].path = QixiRealDeviceEvidenceStore.exportAuditFilename
    expectThrowsContaining(
      "real-device evidence rejects artifact paths using reserved export audit filenames",
      "reserved real-device evidence filenames"
    ) {
      _ = try QixiRealDeviceEvidenceStore.encode(
        reservedExportAuditArtifactPath,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    let customEvidenceURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("custom-real-device-evidence.json")
    expectThrowsContaining(
      "real-device device-log generation rejects artifact paths colliding with the target evidence file",
      "must not overwrite"
    ) {
      _ = try QixiRealDeviceEvidenceStore.writeDeviceLogArtifact(
        for: realDeviceEvidence,
        path: customEvidenceURL.lastPathComponent,
        evidenceURL: customEvidenceURL
      )
    }

    let screenshotArtifact = realDeviceEvidence.artifacts.first(where: { $0.kind == "screenshot" })!
    let symlinkArtifactURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("real-device-ipad-main-link.png")
    try? FileManager.default.removeItem(at: symlinkArtifactURL)
    try FileManager.default.createSymbolicLink(at: symlinkArtifactURL, withDestinationURL: screenshotArtifactURL)
    let symlinkArtifactEvidence = evidenceByReplacingArtifact(
      realDeviceEvidence,
      kind: "screenshot",
      path: "real-device-ipad-main-link.png",
      byteCount: screenshotArtifact.byteCount,
      sha256HexDigest: screenshotArtifact.sha256HexDigest
    )
    expectThrowsContaining(
      "real-device evidence rejects symbolic-link artifact files",
      "symbolic links"
    ) {
      _ = try QixiRealDeviceEvidenceStore.encode(
        symlinkArtifactEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try? FileManager.default.removeItem(at: symlinkArtifactURL)

    let symlinkDirectoryTargetURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("linked-artifacts-target", isDirectory: true)
    let symlinkDirectoryURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("linked-artifacts", isDirectory: true)
    try? FileManager.default.removeItem(at: symlinkDirectoryURL)
    try? FileManager.default.removeItem(at: symlinkDirectoryTargetURL)
    try FileManager.default.createDirectory(at: symlinkDirectoryTargetURL, withIntermediateDirectories: true)
    try ipadLandscapePNG.write(
      to: symlinkDirectoryTargetURL.appendingPathComponent("real-device-ipad-main.png"),
      options: [.atomic]
    )
    try FileManager.default.createSymbolicLink(at: symlinkDirectoryURL, withDestinationURL: symlinkDirectoryTargetURL)
    expectThrowsContaining(
      "real-device evidence fingerprinting rejects symbolic-link artifact directories",
      "symbolic links"
    ) {
      _ = try fingerprintedArtifact(kind: "screenshot", path: "linked-artifacts/real-device-ipad-main.png")
    }
    try? FileManager.default.removeItem(at: symlinkDirectoryURL)
    try? FileManager.default.removeItem(at: symlinkDirectoryTargetURL)

    var wrongByteCountEvidence = realDeviceEvidence
    wrongByteCountEvidence.artifacts[0].byteCount += 1
    expectThrows("real-device evidence rejects mismatched artifact byte counts") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        wrongByteCountEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var tamperedScreenshotPNG = ipadLandscapePNG
    tamperedScreenshotPNG.append(Data("tamper".utf8))
    try tamperedScreenshotPNG.write(to: screenshotArtifactURL, options: [.atomic])
    expectThrows("real-device evidence rejects mismatched artifact SHA-256 digests") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        realDeviceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try Data("not png\n".utf8).write(to: screenshotArtifactURL, options: [.atomic])
    let nonPNGArtifactEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "screenshot",
      path: "real-device-ipad-main.png"
    )
    expectThrows("real-device evidence rejects a non-PNG screenshot artifact") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nonPNGArtifactEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try ipadBlankLandscapePNG.write(to: screenshotArtifactURL, options: [.atomic])
    let blankScreenshotEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "screenshot",
      path: "real-device-ipad-main.png"
    )
    expectThrows("real-device evidence rejects a visually blank screenshot artifact") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        blankScreenshotEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try tinyLandscapePNG.write(to: screenshotArtifactURL, options: [.atomic])
    let tinyScreenshotEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "screenshot",
      path: "real-device-ipad-main.png"
    )
    expectThrows("real-device evidence rejects a too-small screenshot artifact") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        tinyScreenshotEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try ipadPortraitPNG.write(to: screenshotArtifactURL, options: [.atomic])
    let portraitScreenshotEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "screenshot",
      path: "real-device-ipad-main.png"
    )
    expectThrows("real-device evidence rejects a portrait screenshot artifact") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        portraitScreenshotEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try pngHeaderOnly(width: 20_000, height: 10_000).write(to: screenshotArtifactURL, options: [.atomic])
    let oversizedScreenshotEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "screenshot",
      path: "real-device-ipad-main.png"
    )
    expectThrows("real-device evidence rejects an oversized screenshot before bitmap allocation") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        oversizedScreenshotEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try writeSparseFile(
      at: screenshotArtifactURL,
      byteCount: UInt64(QixiRealDeviceEvidenceStore.maxScreenshotArtifactBytes + 1)
    )
    let oversizedScreenshotByteEvidence = evidenceByReplacingArtifact(
      realDeviceEvidence,
      kind: "screenshot",
      path: "real-device-ipad-main.png",
      byteCount: UInt64(QixiRealDeviceEvidenceStore.maxScreenshotArtifactBytes + 1)
    )
    expectThrowsContaining(
      "real-device evidence rejects oversized screenshot artifact bytes before fingerprinting",
      "before fingerprinting"
    ) {
      _ = try QixiRealDeviceEvidenceStore.encode(
        oversizedScreenshotByteEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try ipadLandscapePNG.write(to: screenshotArtifactURL, options: [.atomic])
    let performanceArtifactURL = QixiSnapshotStore.snapshotsDirectory.appendingPathComponent("real-device-instruments.json")
    try Data("not json\n".utf8).write(to: performanceArtifactURL, options: [.atomic])
    let nonJSONPerformanceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects a non-JSON performance artifact") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nonJSONPerformanceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    let wrongPerformanceKindPayload: [String: Any] = [
      "schemaVersion": 1,
      "kind": "performance",
      "source": "instruments",
      "runId": realDeviceEvidence.runId,
      "recordedAt": iso8601String(realDeviceEvidence.recordedAt),
      "measurements": [
        "launch": [
          "coldLaunchMs": realDeviceMeasurements.launch.coldLaunchMs,
          "visualReadyMs": realDeviceMeasurements.launch.visualReadyMs
        ],
        "memory": [
          "peakRSSMB": realDeviceMeasurements.memory.peakRSSMB,
          "postAnalysisRSSMB": realDeviceMeasurements.memory.postAnalysisRSSMB
        ],
        "framePacing": [
          "targetRefreshHz": realDeviceMeasurements.framePacing.targetRefreshHz,
          "observedRefreshHz": realDeviceMeasurements.framePacing.observedRefreshHz,
          "droppedFramePercent": realDeviceMeasurements.framePacing.droppedFramePercent
        ]
      ]
    ]
    let wrongPerformanceKindData = try JSONSerialization.data(
      withJSONObject: wrongPerformanceKindPayload,
      options: [.sortedKeys]
    )
    try wrongPerformanceKindData.write(to: performanceArtifactURL, options: [.atomic])
    let wrongPerformanceKindEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects unstructured performance artifact kind") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        wrongPerformanceKindEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var wrongPerformanceSchemaVersion = wrongPerformanceKindPayload
    wrongPerformanceSchemaVersion["schemaVersion"] = 2
    let wrongPerformanceSchemaVersionData = try JSONSerialization.data(
      withJSONObject: wrongPerformanceSchemaVersion,
      options: [.sortedKeys]
    )
    try wrongPerformanceSchemaVersionData.write(to: performanceArtifactURL, options: [.atomic])
    let wrongPerformanceSchemaVersionEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects unversioned performance artifact schema") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        wrongPerformanceSchemaVersionEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    let wrongPerformanceSourcePayload = try JSONSerialization.jsonObject(
      with: try performanceArtifactData(
        measurements: realDeviceMeasurements,
        recordedAt: realDeviceEvidence.recordedAt,
        runId: realDeviceEvidence.runId
      )
    ) as? [String: Any] ?? [:]
    var wrongPerformanceSource = wrongPerformanceSourcePayload
    wrongPerformanceSource["source"] = "spreadsheet"
    let wrongPerformanceSourceData = try JSONSerialization.data(
      withJSONObject: wrongPerformanceSource,
      options: [.sortedKeys]
    )
    try wrongPerformanceSourceData.write(to: performanceArtifactURL, options: [.atomic])
    let wrongPerformanceSourceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects untrusted performance artifact source") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        wrongPerformanceSourceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    let placeholderPerformancePayload: [String: Any] = [
      "schemaVersion": 1,
      "kind": "qixi-real-device-performance",
      "source": "instruments",
      "runId": realDeviceEvidence.runId,
      "recordedAt": iso8601String(realDeviceEvidence.recordedAt)
    ]
    let placeholderPerformanceData = try JSONSerialization.data(
      withJSONObject: placeholderPerformancePayload,
      options: [.sortedKeys]
    )
    try placeholderPerformanceData.write(to: performanceArtifactURL, options: [.atomic])
    let placeholderPerformanceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects placeholder performance artifact measurements") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        placeholderPerformanceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try performanceArtifactData(
      measurements: realDeviceMeasurements,
      recordedAt: realDeviceEvidence.recordedAt.addingTimeInterval(-5 * 60),
      runId: realDeviceEvidence.runId
    ).write(to: performanceArtifactURL, options: [.atomic])
    let stagedPerformanceRecordedAtEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    _ = try QixiRealDeviceEvidenceStore.encode(
      stagedPerformanceRecordedAtEvidence,
      evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
    )
    try performanceArtifactData(
      measurements: realDeviceMeasurements,
      recordedAt: realDeviceEvidence.recordedAt.addingTimeInterval(5 * 60),
      runId: realDeviceEvidence.runId
    ).write(to: performanceArtifactURL, options: [.atomic])
    let futurePerformanceRecordedAtEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects future performance artifact recordedAt") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        futurePerformanceRecordedAtEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try performanceArtifactData(
      measurements: realDeviceMeasurements,
      recordedAt: realDeviceEvidence.recordedAt.addingTimeInterval(-25 * 60 * 60),
      runId: realDeviceEvidence.runId
    ).write(to: performanceArtifactURL, options: [.atomic])
    let stalePerformanceRecordedAtEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects stale performance artifact recordedAt") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        stalePerformanceRecordedAtEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var mismatchedPerformanceMeasurements = realDeviceMeasurements
    mismatchedPerformanceMeasurements.launch.coldLaunchMs = 901
    try performanceArtifactData(
      measurements: mismatchedPerformanceMeasurements,
      recordedAt: realDeviceEvidence.recordedAt,
      runId: realDeviceEvidence.runId
    ).write(to: performanceArtifactURL, options: [.atomic])
    let mismatchedPerformanceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects mismatched performance artifact measurements") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedPerformanceEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try performanceArtifactData(
      measurements: realDeviceMeasurements,
      recordedAt: realDeviceEvidence.recordedAt,
      runId: "00000000-0000-4000-8000-000000000099"
    ).write(to: performanceArtifactURL, options: [.atomic])
    let mismatchedPerformanceRunIdEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    expectThrows("real-device evidence rejects mismatched performance artifact runId") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedPerformanceRunIdEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try performanceArtifactData(
      measurements: realDeviceMeasurements,
      recordedAt: realDeviceEvidence.recordedAt,
      runId: realDeviceEvidence.runId
    ).write(to: performanceArtifactURL, options: [.atomic])
    try Data("plain device log\n".utf8).write(to: deviceLogArtifactURL, options: [.atomic])
    let nonJSONDeviceLogEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device evidence rejects a non-JSON device log artifact") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nonJSONDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try Data("{\"schemaVersion\":1,\"kind\":\"device-log\"}\n".utf8).write(to: deviceLogArtifactURL, options: [.atomic])
    let placeholderDeviceLogEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device evidence rejects placeholder device log artifact facts") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        placeholderDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var wrongDeviceLogSchemaVersion = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: realDeviceEvidence)
    ) as? [String: Any] ?? [:]
    wrongDeviceLogSchemaVersion["schemaVersion"] = 2
    let wrongDeviceLogSchemaVersionData = try JSONSerialization.data(withJSONObject: wrongDeviceLogSchemaVersion, options: [.sortedKeys])
    try wrongDeviceLogSchemaVersionData.write(to: deviceLogArtifactURL, options: [.atomic])
    let wrongDeviceLogSchemaVersionEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device evidence rejects unversioned device log artifact schema") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        wrongDeviceLogSchemaVersionEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var mismatchedDeviceLog = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: realDeviceEvidence)
    ) as? [String: Any] ?? [:]
    mismatchedDeviceLog["recordedAt"] = iso8601String(realDeviceEvidence.recordedAt.addingTimeInterval(-5 * 60))
    let mismatchedDeviceLogRecordedAtData = try JSONSerialization.data(withJSONObject: mismatchedDeviceLog, options: [.sortedKeys])
    try mismatchedDeviceLogRecordedAtData.write(to: deviceLogArtifactURL, options: [.atomic])
    let mismatchedDeviceLogRecordedAtEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device evidence rejects mismatched device log artifact recordedAt") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedDeviceLogRecordedAtEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    mismatchedDeviceLog = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: realDeviceEvidence)
    ) as? [String: Any] ?? [:]
    mismatchedDeviceLog["runId"] = "00000000-0000-4000-8000-000000000099"
    let mismatchedDeviceLogRunIdData = try JSONSerialization.data(withJSONObject: mismatchedDeviceLog, options: [.sortedKeys])
    try mismatchedDeviceLogRunIdData.write(to: deviceLogArtifactURL, options: [.atomic])
    let mismatchedDeviceLogRunIdEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device evidence rejects mismatched device log artifact runId") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedDeviceLogRunIdEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    mismatchedDeviceLog = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: realDeviceEvidence)
    ) as? [String: Any] ?? [:]
    var mismatchedDeviceLogAnalysis = mismatchedDeviceLog["analysis"] as? [String: Any] ?? [:]
    mismatchedDeviceLogAnalysis["engineId"] = "b6"
    mismatchedDeviceLog["analysis"] = mismatchedDeviceLogAnalysis
    let mismatchedDeviceLogData = try JSONSerialization.data(withJSONObject: mismatchedDeviceLog, options: [.sortedKeys])
    try mismatchedDeviceLogData.write(to: deviceLogArtifactURL, options: [.atomic])
    let mismatchedDeviceLogEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device evidence rejects mismatched device log artifact facts") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try performanceArtifactData(
      measurements: realDeviceMeasurements,
      recordedAt: realDeviceEvidence.recordedAt,
      runId: realDeviceEvidence.runId
    ).write(to: performanceArtifactURL, options: [.atomic])
    realDeviceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "performance",
      path: "real-device-instruments.json"
    )
    try deviceLogArtifactData(evidence: realDeviceEvidence).write(to: deviceLogArtifactURL, options: [.atomic])
    realDeviceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )

    var collapsedPositionIdentityEvidence = realDeviceEvidence
    collapsedPositionIdentityEvidence.analysis.positionIdentity.sameVisibleHistoryBKey =
      collapsedPositionIdentityEvidence.analysis.positionIdentity.sameVisibleHistoryAKey
    collapsedPositionIdentityEvidence.analysis.positionIdentity.sameVisibleHistoryKeysDistinct = false
    expectThrows("real-device evidence rejects collapsed same-visible history position keys") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        collapsedPositionIdentityEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }

    var mismatchedPositionIdentityLog = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: realDeviceEvidence)
    ) as? [String: Any] ?? [:]
    var mismatchedPositionIdentityLogAnalysis = mismatchedPositionIdentityLog["analysis"] as? [String: Any] ?? [:]
    var mismatchedPositionIdentityLogPayload =
      mismatchedPositionIdentityLogAnalysis["positionIdentity"] as? [String: Any] ?? [:]
    mismatchedPositionIdentityLogPayload["sameVisibleHistoryBKey"] = "mismatched-position-key"
    mismatchedPositionIdentityLogAnalysis["positionIdentity"] = mismatchedPositionIdentityLogPayload
    mismatchedPositionIdentityLog["analysis"] = mismatchedPositionIdentityLogAnalysis
    let mismatchedPositionIdentityLogData = try JSONSerialization.data(
      withJSONObject: mismatchedPositionIdentityLog,
      options: [.sortedKeys]
    )
    try mismatchedPositionIdentityLogData.write(to: deviceLogArtifactURL, options: [.atomic])
    let mismatchedPositionIdentityEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("real-device evidence rejects mismatched position identity device log facts") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedPositionIdentityEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try deviceLogArtifactData(evidence: realDeviceEvidence).write(to: deviceLogArtifactURL, options: [.atomic])
    realDeviceEvidence = try evidenceByRefreshingArtifact(
      realDeviceEvidence,
      kind: "device-log",
      path: "real-device.log"
    )

    var bridgeEvidenceWithNativeEngine = realDeviceEvidence
    bridgeEvidenceWithNativeEngine.analysis.nativeEngine = nativeEngineEvidence(
      engine: original.selectedEngine,
      exportedAt: baseDate.addingTimeInterval(8),
      restoredAt: baseDate.addingTimeInterval(10)
    )
    expectThrows("bridge real-device evidence must not include native engine fields") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        bridgeEvidenceWithNativeEngine,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var bridgeEvidenceJSON = realDeviceEvidenceJSON
    var bridgeEvidenceAnalysisJSON = bridgeEvidenceJSON["analysis"] as? [String: Any] ?? [:]
    bridgeEvidenceAnalysisJSON["nativeEngine"] = NSNull()
    bridgeEvidenceJSON["analysis"] = bridgeEvidenceAnalysisJSON
    let bridgeEvidenceWithNullNativeEngineData = try JSONSerialization.data(
      withJSONObject: bridgeEvidenceJSON,
      options: [.sortedKeys]
    )
    let decodedBridgeEvidenceWithNullNativeEngine = try QixiRealDeviceEvidenceStore.decode(
      bridgeEvidenceWithNullNativeEngineData
    )
    expect(
      decodedBridgeEvidenceWithNullNativeEngine == nil,
      "bridge real-device evidence decode rejects an explicit null nativeEngine key"
    )

    var nativeInProcessEvidence = realDeviceEvidence
    nativeInProcessEvidence.app.analysisRuntime = "nativeInProcess"
    nativeInProcessEvidence.backend = nil
    nativeInProcessEvidence.analysis.nativeEngine = nativeEngineEvidence(
      engine: original.selectedEngine,
      exportedAt: baseDate.addingTimeInterval(8),
      restoredAt: baseDate.addingTimeInterval(10)
    )
    try deviceLogArtifactData(evidence: nativeInProcessEvidence).write(to: deviceLogArtifactURL, options: [.atomic])
    nativeInProcessEvidence = try evidenceByRefreshingArtifact(
      nativeInProcessEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    let nativeInProcessEvidenceData = try QixiRealDeviceEvidenceStore.encode(
      nativeInProcessEvidence,
      evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
    )
    let decodedNativeInProcessEvidence = try QixiRealDeviceEvidenceStore.decode(nativeInProcessEvidenceData)
    expect(
      decodedNativeInProcessEvidence == nativeInProcessEvidence,
      "native real-device evidence decodes when backend is absent"
    )
    guard let nativeEvidenceSpec = QixiNativeModelRegistry.spec(for: nativeInProcessEvidence.analysis.engineId) else {
      fail("native real-device evidence should name a supported engine")
    }
    let nativeEvidenceMaximumMemoryMB = Double(nativeEvidenceSpec.maximumMemoryMB)
    var nativeInProcessEvidenceWithExcessiveMemory = nativeInProcessEvidence
    nativeInProcessEvidenceWithExcessiveMemory.measurements.memory.peakRSSMB = nativeEvidenceMaximumMemoryMB + 1
    nativeInProcessEvidenceWithExcessiveMemory.measurements.memory.postAnalysisRSSMB = nativeEvidenceMaximumMemoryMB
    expectThrows("native real-device evidence rejects memory above native model manifest maximum") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nativeInProcessEvidenceWithExcessiveMemory,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var nativeDeviceLog = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: nativeInProcessEvidence)
    ) as? [String: Any] ?? [:]
    var nativeDeviceLogAnalysis = nativeDeviceLog["analysis"] as? [String: Any] ?? [:]
    var nativeDeviceLogEngine = nativeDeviceLogAnalysis["nativeEngine"] as? [String: Any] ?? [:]
    let mismatchedNativeEngineID: AnalysisEngine = nativeInProcessEvidence.analysis.engineId == .b6 ? .b18nbt : .b6
    nativeDeviceLogEngine["engineId"] = mismatchedNativeEngineID.rawValue
    nativeDeviceLogAnalysis["nativeEngine"] = nativeDeviceLogEngine
    nativeDeviceLog["analysis"] = nativeDeviceLogAnalysis
    let mismatchedNativeEngineIDDeviceLogData = try JSONSerialization.data(
      withJSONObject: nativeDeviceLog,
      options: [.sortedKeys]
    )
    try mismatchedNativeEngineIDDeviceLogData.write(to: deviceLogArtifactURL, options: [.atomic])
    let mismatchedNativeEngineIDDeviceLogEvidence = try evidenceByRefreshingArtifact(
      nativeInProcessEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("native real-device evidence rejects mismatched native engine id device log facts") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedNativeEngineIDDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    nativeDeviceLog = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: nativeInProcessEvidence)
    ) as? [String: Any] ?? [:]
    nativeDeviceLogAnalysis = nativeDeviceLog["analysis"] as? [String: Any] ?? [:]
    nativeDeviceLogEngine = nativeDeviceLogAnalysis["nativeEngine"] as? [String: Any] ?? [:]
    nativeDeviceLogEngine["modelSHA256HexDigest"] = String(repeating: "0", count: 64)
    nativeDeviceLogAnalysis["nativeEngine"] = nativeDeviceLogEngine
    nativeDeviceLog["analysis"] = nativeDeviceLogAnalysis
    let mismatchedNativeDeviceLogData = try JSONSerialization.data(
      withJSONObject: nativeDeviceLog,
      options: [.sortedKeys]
    )
    try mismatchedNativeDeviceLogData.write(to: deviceLogArtifactURL, options: [.atomic])
    let mismatchedNativeDeviceLogEvidence = try evidenceByRefreshingArtifact(
      nativeInProcessEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("native real-device evidence rejects mismatched native engine device log facts") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedNativeDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var nativeDeviceLogWithUnexpectedCoreMLPackage = try JSONSerialization.jsonObject(
      with: try deviceLogArtifactData(evidence: nativeInProcessEvidence)
    ) as? [String: Any] ?? [:]
    var nativeDeviceLogUnexpectedPackageAnalysis =
      nativeDeviceLogWithUnexpectedCoreMLPackage["analysis"] as? [String: Any] ?? [:]
    var nativeDeviceLogUnexpectedPackageEngine =
      nativeDeviceLogUnexpectedPackageAnalysis["nativeEngine"] as? [String: Any] ?? [:]
    nativeDeviceLogUnexpectedPackageEngine["coreMLPackages"] = [[
      "resourceName": "unexpected-coreml.mlpackage",
      "variantID": "unexpected",
      "fileCount": 1,
      "totalByteCount": 1,
      "sha256TreeDigest": String(repeating: "1", count: 64)
    ]]
    nativeDeviceLogUnexpectedPackageAnalysis["nativeEngine"] = nativeDeviceLogUnexpectedPackageEngine
    nativeDeviceLogWithUnexpectedCoreMLPackage["analysis"] = nativeDeviceLogUnexpectedPackageAnalysis
    let unexpectedNativeCoreMLPackageDeviceLogData = try JSONSerialization.data(
      withJSONObject: nativeDeviceLogWithUnexpectedCoreMLPackage,
      options: [.sortedKeys]
    )
    try unexpectedNativeCoreMLPackageDeviceLogData.write(to: deviceLogArtifactURL, options: [.atomic])
    let unexpectedNativeCoreMLPackageDeviceLogEvidence = try evidenceByRefreshingArtifact(
      nativeInProcessEvidence,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("native real-device evidence rejects mismatched native engine CoreML package device log facts") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        unexpectedNativeCoreMLPackageDeviceLogEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try deviceLogArtifactData(evidence: nativeInProcessEvidence).write(to: deviceLogArtifactURL, options: [.atomic])
    var nativeInProcessEvidenceWithWrongDigest = nativeInProcessEvidence
    nativeInProcessEvidenceWithWrongDigest.analysis.nativeEngine?.modelSHA256HexDigest = String(repeating: "0", count: 64)
    expectThrows("native real-device evidence rejects mismatched model digest metadata") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nativeInProcessEvidenceWithWrongDigest,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var nativeInProcessEvidenceWithWrongEngineID = nativeInProcessEvidence
    nativeInProcessEvidenceWithWrongEngineID.analysis.nativeEngine?.engineId = mismatchedNativeEngineID
    expectThrows("native real-device evidence rejects native engine id mismatches") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nativeInProcessEvidenceWithWrongEngineID,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var nativeInProcessEvidenceWithUnexpectedCoreMLPackage = nativeInProcessEvidence
    guard var unexpectedCoreMLPackageNativeEngine = nativeInProcessEvidenceWithUnexpectedCoreMLPackage.analysis.nativeEngine else {
      fail("native real-device evidence should have native engine facts")
    }
    unexpectedCoreMLPackageNativeEngine.coreMLPackages.append(
      QixiRealDeviceEvidence.NativeEngine.CoreMLPackage(
        resourceName: "unexpected-coreml.mlpackage",
        variantID: "unexpected",
        fileCount: 1,
        totalByteCount: 1,
        sha256TreeDigest: String(repeating: "1", count: 64)
      )
    )
    nativeInProcessEvidenceWithUnexpectedCoreMLPackage.analysis.nativeEngine = unexpectedCoreMLPackageNativeEngine
    try deviceLogArtifactData(evidence: nativeInProcessEvidenceWithUnexpectedCoreMLPackage)
      .write(to: deviceLogArtifactURL, options: [.atomic])
    let refreshedNativeInProcessEvidenceWithUnexpectedCoreMLPackage = try evidenceByRefreshingArtifact(
      nativeInProcessEvidenceWithUnexpectedCoreMLPackage,
      kind: "device-log",
      path: "real-device.log"
    )
    expectThrows("native real-device evidence rejects mismatched CoreML package metadata") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        refreshedNativeInProcessEvidenceWithUnexpectedCoreMLPackage,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try deviceLogArtifactData(evidence: nativeInProcessEvidence).write(to: deviceLogArtifactURL, options: [.atomic])
    var nativeInProcessEvidenceWithStaleAudit = nativeInProcessEvidence
    nativeInProcessEvidenceWithStaleAudit.analysis.nativeEngine?.tombstoneExportedAt = baseDate.addingTimeInterval(-90_000)
    expectThrows("native real-device evidence rejects stale tombstone audit metadata") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nativeInProcessEvidenceWithStaleAudit,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var nativeInProcessEvidenceWithFutureExportAudit = nativeInProcessEvidence
    nativeInProcessEvidenceWithFutureExportAudit.analysis.nativeEngine?.tombstoneExportedAt =
      nativeInProcessEvidence.recordedAt.addingTimeInterval(60)
    expectThrows("native real-device evidence rejects future tombstone export audit metadata") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nativeInProcessEvidenceWithFutureExportAudit,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var nativeInProcessEvidenceWithFutureRestoreAudit = nativeInProcessEvidence
    nativeInProcessEvidenceWithFutureRestoreAudit.analysis.nativeEngine?.tombstoneRestoredAt =
      nativeInProcessEvidence.recordedAt.addingTimeInterval(60)
    expectThrows("native real-device evidence rejects future tombstone restore audit metadata") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nativeInProcessEvidenceWithFutureRestoreAudit,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var nativeInProcessEvidenceJSON = try JSONSerialization.jsonObject(
      with: nativeInProcessEvidenceData
    ) as? [String: Any] ?? [:]
    nativeInProcessEvidenceJSON["backend"] = NSNull()
    let nativeInProcessEvidenceWithNullBackendData = try JSONSerialization.data(
      withJSONObject: nativeInProcessEvidenceJSON,
      options: [.sortedKeys]
    )
    let decodedNativeInProcessEvidenceWithNullBackend = try QixiRealDeviceEvidenceStore.decode(
      nativeInProcessEvidenceWithNullBackendData
    )
    expect(
      decodedNativeInProcessEvidenceWithNullBackend == nil,
      "native real-device evidence decode rejects an explicit null backend key"
    )
    var nativeInProcessEvidenceWithBackend = nativeInProcessEvidence
    nativeInProcessEvidenceWithBackend.backend = QixiRealDeviceEvidence.Backend(
      url: "",
      status: QixiRealDeviceEvidence.BackendStatus(
        engine: "none",
        engineId: "none",
        state: "ready",
        running: false,
        paused: false
      )
    )
    expectThrows("native real-device evidence must omit backend entirely") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        nativeInProcessEvidenceWithBackend,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    try deviceLogArtifactData(evidence: realDeviceEvidence).write(to: deviceLogArtifactURL, options: [.atomic])

    var simulatorEvidence = realDeviceEvidence
    simulatorEvidence.device.simulator = true
    expectThrows("real-device evidence rejects Simulator records") {
      _ = try QixiRealDeviceEvidenceStore.encode(simulatorEvidence, evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL)
    }
    var loopbackEvidence = realDeviceEvidence
    loopbackEvidence.backend?.url = "http://127.0.0.1:8765"
    expectThrows("real-device evidence rejects loopback backend URLs") {
      _ = try QixiRealDeviceEvidenceStore.encode(loopbackEvidence, evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL)
    }
    var mismatchedBackendEngineEvidence = realDeviceEvidence
    mismatchedBackendEngineEvidence.backend?.status.engineId = "b6"
    expectThrows("real-device evidence requires backend engineId to match analysis engineId") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedBackendEngineEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var mismatchedBackendEngineNameEvidence = realDeviceEvidence
    mismatchedBackendEngineNameEvidence.backend?.status.engine = "katago-metal-mux:b6"
    expectThrows("real-device evidence requires backend engine string to match analysis engineId") {
      _ = try QixiRealDeviceEvidenceStore.encode(
        mismatchedBackendEngineNameEvidence,
        evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL
      )
    }
    var weakFramePacingEvidence = realDeviceEvidence
    weakFramePacingEvidence.measurements.framePacing.observedRefreshHz = 80
    expectThrows("real-device evidence rejects weak 120 Hz frame-pacing measurements") {
      _ = try QixiRealDeviceEvidenceStore.encode(weakFramePacingEvidence, evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL)
    }
    var missingFeatureEvidence = realDeviceEvidence
    missingFeatureEvidence.features.iCloudSyncTested = false
    expectThrows("real-device evidence requires iCloud sync coverage") {
      _ = try QixiRealDeviceEvidenceStore.encode(missingFeatureEvidence, evidenceURL: QixiRealDeviceEvidenceStore.evidenceURL)
    }

    var tombstoneJSON = try JSONSerialization.jsonObject(
      with: try QixiLifecycleTombstoneStore.encode(tombstone)
    ) as? [String: Any] ?? [:]
    tombstoneJSON["schemaVersion"] = QixiLifecycleTombstone.currentSchemaVersion + 100
    let incompatibleTombstone = try JSONSerialization.data(withJSONObject: tombstoneJSON, options: [.sortedKeys])
    let incompatibleTombstoneDecoded = try QixiLifecycleTombstoneStore.decode(incompatibleTombstone)
    expect(incompatibleTombstoneDecoded == nil, "future tombstone schema must not be loaded as current state")

    let olderLocal = snapshot(
      savedAt: baseDate.addingTimeInterval(-60),
      reason: "olderLocal",
      currentPly: 1,
      engine: .b6,
      winrate: 0.47,
      scoreMean: -1.5
    )
    let newerRemote = snapshot(
      savedAt: baseDate.addingTimeInterval(60),
      reason: "newerRemote",
      currentPly: 3,
      engine: .b28nbt,
      winrate: 0.73,
      scoreMean: 7.0
    )

    try QixiSyncStore.write(newerRemote)
    let disabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: olderLocal, syncEnabled: false)
    expect(disabledLaunch == olderLocal, "launch restore ignores newer remote snapshot when iCloud sync is disabled")
    let enabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: olderLocal, syncEnabled: true)
    expect(enabledLaunch == newerRemote, "launch restore imports newer remote snapshot when iCloud sync is enabled")
    let preferred = try QixiSyncStore.preferredSnapshot(localSnapshot: olderLocal)
    expect(preferred == newerRemote, "preferredSnapshot imports newer remote snapshot")
    let nilLocalImportResult = try QixiSyncStore.reconcile(localSnapshot: nil)
    expect(
      nilLocalImportResult.importedSnapshot == newerRemote,
      "reconcile imports remote snapshot when local state is absent"
    )
    expect(
      QixiSnapshotStore.load() == newerRemote,
      "reconcile saves imported remote snapshot when local state is absent"
    )

    let importResult = try QixiSyncStore.reconcile(localSnapshot: olderLocal)
    expect(importResult.importedSnapshot == newerRemote, "reconcile imports newer remote snapshot")
    expect(QixiSnapshotStore.load() == newerRemote, "imported remote snapshot is saved locally")

    let latestLocal = snapshot(
      savedAt: baseDate.addingTimeInterval(120),
      reason: "latestLocal",
      currentPly: 4,
      engine: .b18nbt,
      winrate: 0.81,
      scoreMean: 9.5
    )
    let exportResult = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
    expect(exportResult.importedSnapshot == nil, "reconcile exports newer local snapshot without import")
    let exportedData = try Data(contentsOf: exportResult.snapshotURL)
    let syncBackupURL = exportResult.backupSnapshotURL
    let exportedBackupData = try Data(contentsOf: syncBackupURL)
    let exportedSnapshot = try QixiSnapshotStore.decode(exportedData)
    expect(exportedSnapshot == latestLocal, "exported sync snapshot matches latest local snapshot")
    expect(exportedBackupData == exportedData, "sync write mirrors primary snapshot to remote backup")

    func writeRemoteCopies(_ data: Data) throws {
      try data.write(to: exportResult.snapshotURL, options: [.atomic])
      try data.write(to: syncBackupURL, options: [.atomic])
    }
    try? FileManager.default.removeItem(at: exportResult.snapshotURL)
    try FileManager.default.createSymbolicLink(at: exportResult.snapshotURL, withDestinationURL: syncBackupURL)
    expectThrowsContaining(
      "sync write rejects symbolic-link primary snapshot paths",
      "symbolic links"
    ) {
      try QixiSyncStore.write(latestLocal)
    }
    try? FileManager.default.removeItem(at: exportResult.snapshotURL)
    try QixiSyncStore.write(latestLocal)
    let syncDirectoryURL = exportResult.snapshotURL.deletingLastPathComponent()
    let linkedSyncDirectoryTargetURL = syncDirectoryURL
      .deletingLastPathComponent()
      .appendingPathComponent("linked-sync-snapshot-directory-target", isDirectory: true)
    try? FileManager.default.removeItem(at: syncDirectoryURL)
    try? FileManager.default.removeItem(at: linkedSyncDirectoryTargetURL)
    try FileManager.default.createDirectory(at: linkedSyncDirectoryTargetURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: syncDirectoryURL, withDestinationURL: linkedSyncDirectoryTargetURL)
    expectThrowsContaining(
      "sync write rejects symbolic-link snapshot directories",
      "symbolic links"
    ) {
      try QixiSyncStore.write(latestLocal)
    }
    try? FileManager.default.removeItem(at: syncDirectoryURL)
    try? FileManager.default.removeItem(at: linkedSyncDirectoryTargetURL)
    try QixiSyncStore.write(latestLocal)

    try FileManager.default.removeItem(at: exportResult.snapshotURL)
    let missingPrimaryPreferred = try QixiSyncStore.preferredSnapshot(localSnapshot: olderLocal)
    expect(
      missingPrimaryPreferred == latestLocal,
      "preferredSnapshot recovers from remote backup when primary sync snapshot is missing"
    )
    try QixiSyncStore.write(latestLocal)
    let backupBeforePrimaryCorruption = try Data(contentsOf: syncBackupURL)
    try Data("{not-json".utf8).write(to: exportResult.snapshotURL, options: [.atomic])
    let unreadablePrimaryPreferred = try QixiSyncStore.preferredSnapshot(localSnapshot: olderLocal)
    expect(
      unreadablePrimaryPreferred == latestLocal,
      "preferredSnapshot recovers from remote backup when primary sync snapshot is unreadable"
    )
    let backupAfterPrimaryCorruption = try Data(contentsOf: syncBackupURL)
    expect(
      backupAfterPrimaryCorruption == backupBeforePrimaryCorruption,
      "remote backup is preserved when primary sync snapshot is unreadable"
    )
    try QixiSyncStore.write(latestLocal)
    let backupBeforeAmbiguousPrimary = try Data(contentsOf: syncBackupURL)
    let duplicateRemotePrimaryData = dataByReplacingFirst(
      in: backupBeforeAmbiguousPrimary,
      "\"schemaVersion\":1",
      "\"schemaVersion\":1,\"schemaVersion\":1"
    )
    try duplicateRemotePrimaryData.write(to: exportResult.snapshotURL, options: [.atomic])
    let ambiguousPrimaryPreferred = try QixiSyncStore.preferredSnapshot(localSnapshot: olderLocal)
    expect(
      ambiguousPrimaryPreferred == latestLocal,
      "preferredSnapshot recovers from remote backup when primary sync snapshot has duplicate JSON keys"
    )
    let backupAfterAmbiguousPrimary = try Data(contentsOf: syncBackupURL)
    expect(
      backupAfterAmbiguousPrimary == backupBeforeAmbiguousPrimary,
      "remote backup is preserved when primary sync snapshot has duplicate JSON keys"
    )
    try QixiSyncStore.write(latestLocal)
    let backupBeforeDirectoryPrimary = try Data(contentsOf: syncBackupURL)
    try? FileManager.default.removeItem(at: exportResult.snapshotURL)
    try FileManager.default.createDirectory(at: exportResult.snapshotURL, withIntermediateDirectories: true)
    let directoryPrimaryPreferred = try QixiSyncStore.preferredSnapshot(localSnapshot: olderLocal)
    expect(
      directoryPrimaryPreferred == latestLocal,
      "preferredSnapshot recovers from remote backup when primary sync snapshot is a directory"
    )
    let backupAfterDirectoryPrimary = try Data(contentsOf: syncBackupURL)
    expect(
      backupAfterDirectoryPrimary == backupBeforeDirectoryPrimary,
      "remote backup is preserved when primary sync snapshot is a directory"
    )
    try? FileManager.default.removeItem(at: exportResult.snapshotURL)
    try QixiSyncStore.write(latestLocal)

    let primaryBeforeMissingBackupRepair = try Data(contentsOf: exportResult.snapshotURL)
    try? FileManager.default.removeItem(at: syncBackupURL)
    let missingBackupRepair = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
    expect(
      missingBackupRepair.importedSnapshot == nil,
      "reconcile treats missing remote backup as mirror repair, not an import"
    )
    let primaryAfterMissingBackupRepair = try Data(contentsOf: exportResult.snapshotURL)
    expect(
      primaryAfterMissingBackupRepair == primaryBeforeMissingBackupRepair,
      "remote backup repair preserves an already-valid primary sync snapshot"
    )
    let repairedMissingBackupSnapshot = try QixiSnapshotStore.decode(try Data(contentsOf: syncBackupURL))
    expect(
      repairedMissingBackupSnapshot == latestLocal,
      "reconcile repairs a missing remote backup from the valid primary sync snapshot"
    )

    let primaryBeforeCorruptBackupRepair = try Data(contentsOf: exportResult.snapshotURL)
    try Data("{not-json".utf8).write(to: syncBackupURL, options: [.atomic])
    let corruptBackupRepair = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
    expect(
      corruptBackupRepair.importedSnapshot == nil,
      "reconcile treats corrupted remote backup as mirror repair, not an import"
    )
    let primaryAfterCorruptBackupRepair = try Data(contentsOf: exportResult.snapshotURL)
    expect(
      primaryAfterCorruptBackupRepair == primaryBeforeCorruptBackupRepair,
      "corrupted remote backup repair preserves an already-valid primary sync snapshot"
    )
    let repairedCorruptBackupSnapshot = try QixiSnapshotStore.decode(try Data(contentsOf: syncBackupURL))
    expect(
      repairedCorruptBackupSnapshot == latestLocal,
      "reconcile repairs a corrupted remote backup from the valid primary sync snapshot"
    )

    let identicalResult = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
    expect(identicalResult.importedSnapshot == nil, "reconcile treats identical local and remote snapshots as already synced")
    let identicalRemoteData = try Data(contentsOf: exportResult.snapshotURL)
    expect(
      identicalRemoteData == exportedData,
      "identical timestamp and content does not rewrite the remote snapshot"
    )

    var metadataOnlyRemote = latestLocal
    metadataOnlyRemote.saveReason = "sameTimestampMetadataOnlyRemote"
    let metadataOnlyRemoteData = try QixiSnapshotStore.encode(metadataOnlyRemote)
    try metadataOnlyRemoteData.write(to: exportResult.snapshotURL, options: [.atomic])
    let metadataOnlyPreferred = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
    expect(
      metadataOnlyPreferred == latestLocal,
      "preferredSnapshot ignores same-timestamp remote save metadata differences"
    )
    let metadataOnlyReconcile = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
    expect(
      metadataOnlyReconcile.importedSnapshot == nil,
      "reconcile treats same-timestamp save metadata differences as already synced"
    )
    let metadataOnlyRemoteAfterReconcile = try Data(contentsOf: exportResult.snapshotURL)
    expect(
      metadataOnlyRemoteAfterReconcile == metadataOnlyRemoteData,
      "same-timestamp save metadata differences do not rewrite the remote snapshot"
    )

    let illegalRemoteData = try rawSnapshotData(illegalHistorySnapshot)
    try writeRemoteCopies(illegalRemoteData)
    let illegalRemoteDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      illegalRemoteDisabledLaunch == latestLocal,
      "disabled launch restore ignores illegal remote snapshot"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import an illegal remote snapshot")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "illegal remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot illegal remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite an illegal remote snapshot")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "illegal remote reconcile error names the sync snapshot")
      let stillIllegalRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillIllegalRemoteData == illegalRemoteData, "illegal remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected illegal remote sync error: \(error)")
    }

    let invalidPlyRemoteData = try rawSnapshotData(beyondEndPlySnapshot)
    try writeRemoteCopies(invalidPlyRemoteData)
    let invalidPlyDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      invalidPlyDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with invalid current ply"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with invalid current ply")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid current-ply remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot invalid current-ply remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with invalid current ply")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid current-ply remote reconcile error names the sync snapshot")
      let stillInvalidPlyRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillInvalidPlyRemoteData == invalidPlyRemoteData, "invalid current-ply remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected invalid current-ply sync error: \(error)")
    }

    let invalidKomiRemoteData = try rawSnapshotData(invalidKomiSnapshot)
    try writeRemoteCopies(invalidKomiRemoteData)
    let invalidKomiDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      invalidKomiDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with invalid komi"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with invalid komi")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid komi remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot invalid komi remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with invalid komi")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid komi remote reconcile error names the sync snapshot")
      let stillInvalidKomiRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillInvalidKomiRemoteData == invalidKomiRemoteData, "invalid komi remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected invalid komi sync error: \(error)")
    }

    let invalidCacheRemoteData = try rawSnapshotData(offBoardCandidateSnapshot)
    try writeRemoteCopies(invalidCacheRemoteData)
    let invalidCacheDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      invalidCacheDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with invalid analysis cache"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with invalid analysis cache")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid analysis-cache remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot invalid analysis-cache remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with invalid analysis cache")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid analysis-cache remote reconcile error names the sync snapshot")
      let stillInvalidCacheRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillInvalidCacheRemoteData == invalidCacheRemoteData, "invalid analysis-cache remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected invalid analysis-cache sync error: \(error)")
    }

    let mismatchedCacheRemoteData = try rawSnapshotData(mismatchedCacheKeySnapshot)
    try writeRemoteCopies(mismatchedCacheRemoteData)
    let mismatchedCacheDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      mismatchedCacheDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with mismatched analysis cache key"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with mismatched analysis cache key")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "mismatched analysis-cache remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot mismatched analysis-cache remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with mismatched analysis cache key")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "mismatched analysis-cache remote reconcile error names the sync snapshot")
      let stillMismatchedCacheRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillMismatchedCacheRemoteData == mismatchedCacheRemoteData, "mismatched analysis-cache remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected mismatched analysis-cache sync error: \(error)")
    }

    let wrongEngineCacheRemoteData = try rawSnapshotData(wrongEngineCacheKeySnapshot)
    try writeRemoteCopies(wrongEngineCacheRemoteData)
    let wrongEngineCacheDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      wrongEngineCacheDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with wrong-engine analysis cache key"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with wrong-engine analysis cache key")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "wrong-engine analysis-cache remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot wrong-engine analysis-cache remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with wrong-engine analysis cache key")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "wrong-engine analysis-cache remote reconcile error names the sync snapshot")
      let stillWrongEngineCacheRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillWrongEngineCacheRemoteData == wrongEngineCacheRemoteData, "wrong-engine analysis-cache remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected wrong-engine analysis-cache sync error: \(error)")
    }

    let malformedSemanticCacheRemoteData = try rawSnapshotData(malformedSemanticCacheKeySnapshot)
    try writeRemoteCopies(malformedSemanticCacheRemoteData)
    let malformedSemanticCacheDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      malformedSemanticCacheDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with malformed semantic cache key"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with malformed semantic cache key")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "malformed semantic cache remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot malformed semantic cache error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with malformed semantic cache key")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "malformed semantic cache remote reconcile error names the sync snapshot")
      let stillMalformedSemanticCacheRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillMalformedSemanticCacheRemoteData == malformedSemanticCacheRemoteData, "malformed semantic cache remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected malformed semantic cache sync error: \(error)")
    }

    let malformedBitPatternRemoteData = try rawSnapshotData(malformedLeadingZeroBitsSnapshot)
    try writeRemoteCopies(malformedBitPatternRemoteData)
    let malformedBitPatternDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      malformedBitPatternDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with malformed semantic cache bit fields"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with malformed semantic cache bit fields")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "malformed semantic bit-field remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot malformed semantic bit-field error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with malformed semantic cache bit fields")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "malformed semantic bit-field remote reconcile error names the sync snapshot")
      let stillMalformedBitPatternRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillMalformedBitPatternRemoteData == malformedBitPatternRemoteData, "malformed semantic bit-field remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected malformed semantic bit-field sync error: \(error)")
    }

    let invalidSemanticSettingRemoteData = try rawSnapshotData(negativeRootNoiseSemanticSnapshot)
    try writeRemoteCopies(invalidSemanticSettingRemoteData)
    let invalidSemanticSettingDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      invalidSemanticSettingDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with invalid semantic cache settings"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with invalid semantic cache settings")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid semantic cache setting remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot invalid semantic cache setting error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with invalid semantic cache settings")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "invalid semantic cache setting remote reconcile error names the sync snapshot")
      let stillInvalidSemanticSettingRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillInvalidSemanticSettingRemoteData == invalidSemanticSettingRemoteData, "invalid semantic cache setting remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected invalid semantic cache setting sync error: \(error)")
    }

    let illegalSemanticHistoryRemoteData = try rawSnapshotData(illegalHistorySemanticSnapshot)
    try writeRemoteCopies(illegalSemanticHistoryRemoteData)
    let illegalSemanticHistoryDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      illegalSemanticHistoryDisabledLaunch == latestLocal,
      "disabled launch restore ignores remote snapshot with illegal semantic cache history"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not import a remote snapshot with illegal semantic cache history")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "illegal semantic cache history remote snapshot is reported as incompatible")
    } catch {
      fail("unexpected preferredSnapshot illegal semantic cache history error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a remote snapshot with illegal semantic cache history")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "illegal semantic cache history remote reconcile error names the sync snapshot")
      let stillIllegalSemanticHistoryRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillIllegalSemanticHistoryRemoteData == illegalSemanticHistoryRemoteData, "illegal semantic cache history remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected illegal semantic cache history sync error: \(error)")
    }

    let conflictingRemote = snapshot(
      savedAt: latestLocal.savedAt,
      reason: "sameTimestampRemoteConflict",
      currentPly: 5,
      engine: .b28nbt,
      winrate: 0.42,
      scoreMean: -3.0
    )
    let conflictingRemoteData = try QixiSnapshotStore.encode(conflictingRemote)
    try writeRemoteCopies(conflictingRemoteData)
    let conflictDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      conflictDisabledLaunch == latestLocal,
      "disabled launch restore ignores same-timestamp divergent remote snapshot"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not silently ignore a same-timestamp divergent remote snapshot")
    } catch QixiSyncError.conflictingRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "preferredSnapshot conflict names the sync snapshot")
    } catch {
      fail("unexpected preferredSnapshot same-timestamp conflict error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite a same-timestamp divergent remote snapshot")
    } catch QixiSyncError.conflictingRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "conflicting remote error names the sync snapshot")
      let stillConflictingRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillConflictingRemoteData == conflictingRemoteData, "same-timestamp divergent remote snapshot is not overwritten")
    } catch {
      fail("unexpected same-timestamp remote conflict error: \(error)")
    }

    var futureRemoteJSON = try JSONSerialization.jsonObject(
      with: try QixiSnapshotStore.encode(newerRemote)
    ) as? [String: Any] ?? [:]
    futureRemoteJSON["schemaVersion"] = QixiAppSnapshot.currentSchemaVersion + 100
    let futureRemoteData = try JSONSerialization.data(withJSONObject: futureRemoteJSON, options: [.sortedKeys])
    try writeRemoteCopies(futureRemoteData)
    let futureDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      futureDisabledLaunch == latestLocal,
      "disabled launch restore ignores incompatible remote snapshot"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not silently ignore an incompatible remote snapshot")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "preferredSnapshot incompatible remote names the sync snapshot")
    } catch {
      fail("unexpected preferredSnapshot incompatible remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite an incompatible remote snapshot")
    } catch QixiSyncError.incompatibleRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "incompatible remote error names the sync snapshot")
      let stillFutureRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillFutureRemoteData == futureRemoteData, "incompatible remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected incompatible remote sync error: \(error)")
    }

    try writeRemoteCopies(Data("{not-json".utf8))
    let unreadableDisabledLaunch = try QixiSyncStore.launchSnapshot(localSnapshot: latestLocal, syncEnabled: false)
    expect(
      unreadableDisabledLaunch == latestLocal,
      "disabled launch restore ignores unreadable remote snapshot"
    )
    do {
      _ = try QixiSyncStore.preferredSnapshot(localSnapshot: latestLocal)
      fail("preferredSnapshot must not silently ignore an unreadable remote snapshot")
    } catch QixiSyncError.unreadableRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "preferredSnapshot unreadable remote names the sync snapshot")
    } catch {
      fail("unexpected preferredSnapshot unreadable remote error: \(error)")
    }
    do {
      _ = try QixiSyncStore.reconcile(localSnapshot: latestLocal)
      fail("sync reconcile must not overwrite an unreadable remote snapshot")
    } catch QixiSyncError.unreadableRemoteSnapshot(let url) {
      expect(url.lastPathComponent == QixiSnapshotStore.snapshotFilename, "unreadable remote error names the sync snapshot")
      let stillUnreadableRemoteData = try Data(contentsOf: exportResult.snapshotURL)
      expect(stillUnreadableRemoteData == Data("{not-json".utf8), "unreadable remote snapshot is not overwritten by local state")
    } catch {
      fail("unexpected unreadable remote sync error: \(error)")
    }

    let rootPath = snapshotsRoot.resolvingSymlinksInPath().path
    let fixedHomePath = URL(fileURLWithPath: fixedHome).resolvingSymlinksInPath().path
    expect(rootPath.hasPrefix(fixedHomePath), "snapshot directory is isolated under CFFIXED_USER_HOME")
    print("Persistence and sync smoke passed")
  }

  static func snapshot(
    savedAt: Date,
    reason: String,
    currentPly: Int,
    engine: AnalysisEngine,
    winrate: Double,
    scoreMean: Double,
    mainLine: [BoardMove]? = nil,
    komi: Double = 7.5
  ) -> QixiAppSnapshot {
    let resolvedMainLine = mainLine ?? [
      BoardMove(color: .black, x: 3, y: 3),
      BoardMove(pass: .white),
      BoardMove(color: .black, x: 15, y: 15),
      BoardMove(color: .white, x: 4, y: 4),
      BoardMove(color: .black, x: 16, y: 16)
    ]
    let rootMoves = Array(resolvedMainLine.prefix(max(0, min(currentPly, resolvedMainLine.count))))
    let cacheKey = QixiPositionIdentity.cacheKey(
      engine: engine,
      moves: rootMoves,
      komi: komi,
      rootNoise: QixiAnalysisLimits.defaultRootNoise
    )
    return QixiAppSnapshot(
      savedAt: savedAt,
      saveReason: reason,
      selectedEngine: engine,
      currentPly: currentPly,
      mainLine: resolvedMainLine,
      recognizedSetupStones: nil,
      komi: komi,
      showTerritory: true,
      analysisByEngine: [
        engine.rawValue: [
          cacheKey: cachedAnalysis(
            savedAt: savedAt,
            positionKey: cacheKey,
            winrate: winrate,
            scoreMean: scoreMean
          )
        ]
      ]
    )
  }

  static func cachedAnalysis(
    savedAt: Date,
    positionKey: String,
    winrate: Double,
    scoreMean: Double
  ) -> QixiCachedAnalysis {
    QixiCachedAnalysis(
      savedAt: savedAt,
      positionKey: positionKey,
      winrate: winrate,
      scoreMean: scoreMean,
      visits: 192,
      candidates: [
        CandidateMove(x: 3, y: 3, rank: 1, winrate: winrate, visits: 128, scoreMean: scoreMean),
        CandidateMove(x: 15, y: 15, rank: 2, winrate: max(0.0, winrate - 0.04), visits: 64, scoreMean: scoreMean - 1.5)
      ],
      territory: [
        TerritoryPoint(x: 3, y: 3, ownership: -0.82),
        TerritoryPoint(x: 15, y: 15, ownership: 0.74)
      ]
    )
  }

  static func rawSnapshotData(_ snapshot: QixiAppSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
  }

  static func dataByReplacingFirst(in data: Data, _ needle: String, _ replacement: String) -> Data {
    guard let text = String(data: data, encoding: .utf8) else {
      fail("test fixture data is not UTF-8")
    }
    guard let range = text.range(of: needle) else {
      fail("test fixture data is missing \(needle)")
    }
    return Data((text[..<range.lowerBound] + replacement + text[range.upperBound...]).utf8)
  }

  static func pngWithGrid(width: Int, height: Int, drawGrid: Bool = true) throws -> Data {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var buffer = [UInt8](repeating: 0xE2, count: bytesPerRow * height)
    let marginX = max(20, width / 12)
    let marginY = max(20, height / 12)
    let spanX = max(1, width - 2 * marginX)
    let spanY = max(1, height - 2 * marginY)
    let verticals = Set((0..<19).map { marginX + Int((Double(spanX) * Double($0) / 18.0).rounded()) })
    let horizontals = Set((0..<19).map { marginY + Int((Double(spanY) * Double($0) / 18.0).rounded()) })
    let starPoints = [3, 9, 15].flatMap { x in
      [3, 9, 15].map { y in
        (
          marginX + Int((Double(spanX) * Double(x) / 18.0).rounded()),
          marginY + Int((Double(spanY) * Double(y) / 18.0).rounded())
        )
      }
    }
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * bytesPerRow + x * bytesPerPixel
        var value: UInt8 = 0xE2
        if drawGrid && (verticals.contains(x) || horizontals.contains(y)) {
          value = 0x28
        }
        if drawGrid {
          for (starX, starY) in starPoints {
            let dx = x - starX
            let dy = y - starY
            if dx * dx + dy * dy <= 16 {
              value = 0x18
              break
            }
          }
        }
        buffer[offset] = value
        buffer[offset + 1] = value
        buffer[offset + 2] = value
        buffer[offset + 3] = 0xFF
      }
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(buffer) as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
      fail("could not create PNG fixture image")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
      fail("could not create PNG fixture destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      fail("could not encode PNG fixture")
    }
    return output as Data
  }

  static func pngHeaderOnly(width: UInt32, height: UInt32) -> Data {
    var data = QixiRealDeviceEvidenceStore.pngSignature
    appendUInt32(13, to: &data)
    data.append(Data("IHDR".utf8))
    appendUInt32(width, to: &data)
    appendUInt32(height, to: &data)
    data.append(contentsOf: [8, 2, 0, 0, 0])
    appendUInt32(0, to: &data)
    return data
  }

  static func nativeEngineEvidence(
    engine: AnalysisEngine,
    exportedAt: Date,
    restoredAt: Date
  ) -> QixiRealDeviceEvidence.NativeEngine {
    guard let spec = QixiNativeModelRegistry.spec(for: engine) else {
      fail("native engine evidence helper expected a model-backed engine")
    }
    return QixiRealDeviceEvidence.NativeEngine(
      modelDigestVerified: true,
      engineId: engine,
      modelResourceName: spec.resourceName,
      modelByteCount: spec.expectedByteCount,
      modelSHA256HexDigest: spec.sha256HexDigest,
      coreMLPackages: spec.coreMLPackages.map { packageSpec in
        QixiRealDeviceEvidence.NativeEngine.CoreMLPackage(
          resourceName: packageSpec.resourceName,
          variantID: packageSpec.variantID,
          fileCount: packageSpec.expectedFileCount,
          totalByteCount: packageSpec.expectedTotalByteCount,
          sha256TreeDigest: packageSpec.sha256TreeDigest
        )
      },
      tombstoneExported: true,
      tombstoneFilename: QixiEngineTombstoneStore.tombstoneFilename,
      tombstoneExportedAt: exportedAt,
      tombstoneRestored: true,
      tombstoneRestoredAt: restoredAt
    )
  }

  static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  static func firstCachedAnalysis(in snapshot: QixiAppSnapshot) -> QixiCachedAnalysis {
    let engineKey = snapshot.selectedEngine.rawValue
    guard let cache = snapshot.analysisByEngine[engineKey]?.values.first else {
      fail("snapshot test helper expected at least one cached analysis entry")
    }
    return cache
  }

  static func runRealDeviceEvidencePreflight(evidenceURL: URL, backendURL: String) throws {
    guard let script = ProcessInfo.processInfo.environment["QIXI_REAL_DEVICE_PREFLIGHT_SCRIPT"],
          !script.isEmpty else {
      fail("QIXI_REAL_DEVICE_PREFLIGHT_SCRIPT must point to the Python release evidence preflight")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script, "--evidence", evidenceURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["QIXI_DEVICE_BACKEND_URL"] = backendURL
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    expect(
      process.terminationStatus == 0,
      "Python real-device evidence preflight should accept Swift output: \(output)"
    )
    expect(
      output.contains("Real-device evidence preflight passed"),
      "Python real-device evidence preflight prints success for Swift output"
    )
  }

  static func snapshotWithMutatedCache(
    _ snapshot: QixiAppSnapshot,
    _ mutate: (inout QixiCachedAnalysis) -> Void
  ) -> QixiAppSnapshot {
    var result = snapshot
    let engineKey = snapshot.selectedEngine.rawValue
    guard let cacheKey = result.analysisByEngine[engineKey]?.keys.sorted().first,
          var cache = result.analysisByEngine[engineKey]?[cacheKey] else {
      fail("snapshot test helper expected at least one cached analysis entry")
    }
    mutate(&cache)
    result.analysisByEngine[engineKey]?[cacheKey] = cache
    return result
  }

  static func snapshotWithReplacedCacheKey(
    _ snapshot: QixiAppSnapshot,
    cacheKey: String
  ) -> QixiAppSnapshot {
    var result = snapshot
    let engineKey = snapshot.selectedEngine.rawValue
    guard let originalCacheKey = result.analysisByEngine[engineKey]?.keys.sorted().first,
          var cache = result.analysisByEngine[engineKey]?[originalCacheKey] else {
      fail("snapshot test helper expected at least one cached analysis entry")
    }
    cache.positionKey = cacheKey
    result.analysisByEngine[engineKey] = [cacheKey: cache]
    return result
  }

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fail(message)
    }
  }

  static func expectThrows(_ message: String, _ body: () throws -> Void) {
    do {
      try body()
      fail("expected throw for \(message)")
    } catch {
      return
    }
  }

  static func expectThrowsContaining(
    _ message: String,
    _ expectedSubstring: String,
    _ body: () throws -> Void
  ) {
    do {
      try body()
      fail("expected throw for \(message)")
    } catch {
      let rendered = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      expect(
        rendered.contains(expectedSubstring),
        "\(message) should mention \(expectedSubstring), got: \(rendered)"
      )
    }
  }

  static func writeSparseFile(at url: URL, byteCount: UInt64) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: byteCount)
    try handle.close()
  }

  static func fail(_ message: String) -> Never {
    fputs("Persistence and sync smoke failed: \(message)\n", stderr)
    exit(1)
  }
}
