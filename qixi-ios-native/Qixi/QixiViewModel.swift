import Foundation
import SwiftUI
import UIKit

private enum QixiAutomationEvidenceError: Error, LocalizedError {
  case missingEnvironment(String)
  case invalidInteger(String)
  case invalidDouble(String)
  case invalidDate(String)
  case invalidOutputPath(String)
  case forbiddenBackendEnvironment(String)

  var errorDescription: String? {
    switch self {
    case .missingEnvironment(let key):
      return "Missing required real-device evidence environment value \(key)."
    case .invalidInteger(let key):
      return "Real-device evidence environment value \(key) must be an integer."
    case .invalidDouble(let key):
      return "Real-device evidence environment value \(key) must be a finite number."
    case .invalidDate(let key):
      return "Real-device evidence environment value \(key) must be an ISO-8601 timestamp."
    case .invalidOutputPath(let key):
      return "Real-device evidence environment value \(key) must be a portable relative JSON path or an absolute JSON file path."
    case .forbiddenBackendEnvironment(let keys):
      return "nativeInProcess real-device evidence automation must not set backend transport environment values: \(keys)."
    }
  }
}

private enum QixiAutomationEvidenceExportTrigger {
  case analysis
  case launch

  var environmentKey: String {
    switch self {
    case .analysis:
      return "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_ANALYSIS"
    case .launch:
      return "QIXI_EXPORT_REAL_DEVICE_EVIDENCE_ON_LAUNCH"
    }
  }
}

private struct QixiNextMoveOverlayContext: Equatable {
  var x: Int
  var y: Int
  var color: StoneColor
  var childRootVisits: Int
  var childRootCache: QixiCachedAnalysis?

  var pointID: Int {
    y * 19 + x
  }
}

enum QixiBackendTransition: Equatable {
  case restoringState
  case switchingEngine
  case exportingState
  case importingState
  case installingModel
  case memoryUnload
  case memoryReload

  var statusText: String {
    switch self {
    case .restoringState:
      return L10n.text(.backendRestoringState)
    case .switchingEngine:
      return L10n.text(.backendLoadingEngine)
    case .exportingState:
      return L10n.text(.mctsStateExporting)
    case .importingState:
      return L10n.text(.mctsStateImporting)
    case .installingModel:
      return L10n.text(.backendInstallingModel)
    case .memoryUnload:
      return L10n.text(.memoryPressureUnloading)
    case .memoryReload:
      return L10n.text(.memoryPressureReloading)
    }
  }

  var jobKind: QixiBlockingJob.Kind {
    switch self {
    case .restoringState: return .restoringState
    case .switchingEngine: return .switchingEngine
    case .exportingState: return .exportingState
    case .importingState: return .importingState
    case .installingModel: return .installingModel
    case .memoryUnload: return .memoryUnload
    case .memoryReload: return .memoryReload
    }
  }
}

@MainActor
final class QixiViewModel: ObservableObject, QixiCoreMutationHost, QixiMemoryPressureHost, QixiPersistenceHost, QixiUtilitySheetHost {
  private static let variationRootID = QixiVariationModel.rootID
  // Autosave interval / debounce live on QixiPersistenceCoordinator.
  // Analysis cache LRU cap lives on QixiAnalysisCache.
  private static let defaultKomi = QixiAnalysisLimits.defaultKomi
  private static let defaultRootNoise = QixiAnalysisLimits.defaultRootNoise
  private static let realtimeAnalysisInitialVisitBatch = 4
  private static let realtimeAnalysisMinimumVisitBatch = 1
  private static let realtimeAnalysisMaximumVisitBatch = 64
  private static let realtimeAnalysisTargetResponseInterval: TimeInterval = 0.10
  private static let realtimeAnalysisMinimumDisplayVisits = 1
  private static let realtimeAnalysisMinimumDisplayCandidates = 3
  private static let realtimeAnalysisAutosaveEveryRounds = 16
  private static let realtimeAnalysisDiagnosticEveryRounds = 16

  @Published var selectedEngine: AnalysisEngine = .none
  @Published var hermesStatus: HermesStatus = .ready
  @Published var currentPly: Int = 0 {
    didSet {
      updateBoardMoveCache()
    }
  }
  @Published var mainLine: [BoardMove] {
    didSet {
      updateBoardMoveCache()
    }
  }
  @Published var candidates: [CandidateMove] = [] {
    didSet {
      updateCandidateCaches()
    }
  }
  @Published var territory: [TerritoryPoint] = []
  @Published var showTerritory = false {
    didSet {
      guard !isApplyingSnapshot else { return }
      persistence.saveSoon(reason: "territoryVisibilityChanged")
    }
  }
  @Published var komi: Double {
    didSet {
      let normalized = QixiAnalysisLimits.normalizedKomi(komi)
      if normalized != komi {
        komi = normalized
      }
      guard !isApplyingSnapshot else { return }
      guard komi != oldValue else { return }
      persistence.saveSoon(reason: "komiChanged")
      refreshVisibleAnalysisForCurrentSettings()
      scheduleAnalysisRefresh(reason: "komiChanged")
    }
  }
  @Published var rootNoise: Double = QixiViewModel.defaultRootNoise {
    didSet {
      let normalized = QixiAnalysisLimits.normalizedRootNoise(rootNoise)
      if normalized != rootNoise {
        rootNoise = normalized
      }
      guard !isApplyingSnapshot else { return }
      guard rootNoise != oldValue else { return }
      refreshVisibleAnalysisForCurrentSettings()
      scheduleAnalysisRefresh(reason: "rootNoiseChanged")
    }
  }
  @Published private(set) var currentWinrate: Double = 0.5
  @Published private(set) var currentScoreMean: Double = 0.0
  @Published private(set) var lastSaveError: String?
  @Published private(set) var lastEngineError: String?
  @Published private(set) var syncStatus = QixiSyncStatus()
  /// Legacy name kept for diagnostics; prefer `activeBlockingJob`.
  @Published private(set) var backendTransition: QixiBackendTransition? = nil
  @Published private(set) var activeBlockingJob: QixiBlockingJob? = nil
  @Published var language: AppLanguage = AppLanguage.current
  @Published var onboardingCompleted: Bool = false
  @Published var iCloudSyncEnabled: Bool = false
  @Published var utilitySheet: QixiUtilitySheet?
  @Published private(set) var lastBoardRecognition: QixiBoardRecognitionResult?
  private(set) var visibleBoardStones: [VisibleBoardStone] = []
  private(set) var visibleStoneColorsByID: [Int: StoneColor] = [:]
  private(set) var occupiedBoardPointIDs = Set<Int>()
  private(set) var nextMoveCapturedBoardPointIDs = Set<Int>()

  let analysisService: any QixiAnalysisService
  private var analysisTask: Task<Void, Never>?
  private var analysisRefreshTask: Task<Void, Never>?
  private var engineTombstoneTask: Task<Void, Never>?
  private var analysisGeneration = 0
  private var analysisCache = QixiAnalysisCache()
  private let persistence = QixiPersistenceCoordinator()
  private let syncCoordinator = QixiSyncCoordinator()
  private var cachedBoardMoves: [BoardMove] = []
  private var bestCandidateWinrate: Double?
  private var cachedVisibleCandidates: [CandidateMove] = []
  private var cachedVisibleCandidateOverlays: [VisibleCandidateOverlay] = []
  private var recognizedSetupStones: [BoardSetupStone]?
  private var variation = QixiVariationModel()
  private var isApplyingSnapshot = false
  private var hasExportedAutomationRealDeviceEvidence = false
  private var memorySampler: QixiMemorySampler?
  private let memoryPressurePolicy = QixiMemoryPressurePolicy()
  var coreBackendEpoch: UInt64 = 0
  var coreRevision: UInt64 = 0
  private var coreCurrentRootID: UInt32 = 0
  private let coreMutationQueue = QixiCoreMutationQueue()
  private let blockingSession = QixiBlockingSession()

  var coreBackendService: (any QixiCoreBackendService)? {
    analysisService as? any QixiCoreBackendService
  }

  // Exposed for QixiCoreMutationHost
  var analysisServiceForHost: any QixiAnalysisService { analysisService }

  var isBackendInteractionBlocked: Bool {
    blockingSession.isBlocked
  }

  @discardableResult
  private func beginBackendTransition(_ transition: QixiBackendTransition) -> UInt64 {
    let token = blockingSession.begin(transition)
    backendTransition = blockingSession.backendTransition
    activeBlockingJob = blockingSession.activeBlockingJob
    return token
  }

  private func updateBackendTransitionProgress(
    _ token: UInt64?,
    phase: String? = nil,
    fraction: Double? = nil,
    detail: String? = nil
  ) {
    blockingSession.update(token, phase: phase, fraction: fraction, detail: detail)
    activeBlockingJob = blockingSession.activeBlockingJob
    backendTransition = blockingSession.backendTransition
  }

  private func finishBackendTransition(_ token: UInt64?) {
    blockingSession.finish(token)
    activeBlockingJob = blockingSession.activeBlockingJob
    backendTransition = blockingSession.backendTransition
  }

  private func startIoProgressPolling(for token: UInt64) {
    guard let service = analysisService as? NativeKataGoAnalysisService else { return }
    blockingSession.startIoProgressPolling(for: token, service: service) { [weak self] token, phase, fraction, detail in
      self?.updateBackendTransitionProgress(token, phase: phase, fraction: fraction, detail: detail)
    }
  }

  private func stopIoProgressPolling() {
    blockingSession.stopIoProgressPolling()
  }


  init(analysisService: (any QixiAnalysisService)? = nil) {
    let processEnvironment = ProcessInfo.processInfo.environment
    let processArguments = ProcessInfo.processInfo.arguments
    self.analysisService = analysisService ?? QixiAnalysisServiceFactory.makeDefaultService()
    self.language = AppLanguage.current
    self.onboardingCompleted = QixiPreferences.shouldSkipOnboardingForAutomation ||
      UserDefaults.standard.bool(forKey: QixiPreferences.onboardingCompletedKey)
    let launchSyncOverride = QixiPreferences.iCloudSyncEnabledAutomationOverride
    let requestedLaunchSyncEnabled = launchSyncOverride ??
      UserDefaults.standard.bool(forKey: QixiPreferences.iCloudSyncEnabledKey)
    let launchSyncEnabled = QixiSyncStore.launchSyncEnabled(
      requestedEnabled: requestedLaunchSyncEnabled,
      automationOverride: launchSyncOverride
    )
    self.iCloudSyncEnabled = launchSyncEnabled

    let localSnapshot = QixiSnapshotStore.load()
    let preferredSnapshot: QixiAppSnapshot?
    do {
      preferredSnapshot = try QixiSyncStore.launchSnapshot(
        localSnapshot: localSnapshot,
        syncEnabled: launchSyncEnabled
      )
    } catch {
      preferredSnapshot = localSnapshot
      self.syncStatus = QixiSyncStatus(
        provider: .localFallback,
        lastSyncAt: nil,
        lastError: String(describing: error)
      )
    }

    if let snapshot = preferredSnapshot {
      let restoredSetupStones = Self.normalizedSetupStones(snapshot.recognizedSetupStones ?? [])
      let hasRestoredSetup = !restoredSetupStones.isEmpty
      self.recognizedSetupStones = hasRestoredSetup ? restoredSetupStones : nil
      let restoredMainLine = snapshot.mainLine.isEmpty && !hasRestoredSetup ? Self.sampleLine : snapshot.mainLine
      self.mainLine = restoredMainLine
      self.komi = snapshot.komi
      self.currentPly = min(max(0, snapshot.currentPly), restoredMainLine.count)
      self.selectedEngine = snapshot.selectedEngine
      self.showTerritory = snapshot.showTerritory
      self.analysisCache.replaceAll(snapshot.analysisByEngine)
    } else {
      self.mainLine = Self.sampleLine
      self.komi = Self.defaultKomi
      self.currentPly = min(8, Self.sampleLine.count)
    }

    resetVariationTree(from: mainLine, currentPly: currentPly)
    updateBoardMoveCache()
    if selectedEngine == .none || !restoreCachedAnalysisForCurrentPosition() {
      refreshLocalChartAnchor()
    }
    if let automationStatus = HermesStatus(automationValue: processEnvironment["QIXI_HERMES_STATUS"]) {
      hermesStatus = automationStatus
    }
    applyAutomationEngineErrorIfNeeded(environment: processEnvironment)
    applyAutomationSyncStatusIfNeeded(environment: processEnvironment)
    applyAutomationAnalysisFixtureIfNeeded(environment: processEnvironment)
    if applyAutomationInitialEngineIfNeeded(environment: processEnvironment),
       selectedEngine != .none,
       !restoreCachedAnalysisForCurrentPosition() {
      clearVisibleAnalysisAndRefreshAnchor()
    }
    updateBoardMoveCache()
    updateCandidateCaches()
    let wroteAutomationLifecycleTombstone = handleAutomationLifecycleTombstoneIfNeeded(
      environment: processEnvironment,
      arguments: processArguments
    )
    persistence.attach(host: self)
    persistence.startAutosaveTimer()
    syncCoordinator.attach(host: self)
    if !wroteAutomationLifecycleTombstone {
      persistence.saveSoon(reason: "launchReady")
    }
    let launchTransitionToken = beginBackendTransition(.restoringState)
    Task { [self] in
      await resumeAnalysisAfterLaunch(transitionToken: launchTransitionToken)
    }
    memorySampler = QixiMemorySampler { [weak self] in
      self?.memoryTelemetryContext() ?? QixiMemoryTelemetryContext.empty
    }
    memorySampler?.start()
    memorySampler?.onSample = { [weak self] sample in
      self?.memoryPressurePolicy.noteFootprintSample(physFootprintBytes: sample.physFootprintBytes)
    }
    memoryPressurePolicy.start(host: self)
    utilitySheet = QixiUtilitySheet(automationValue: processEnvironment["QIXI_OPEN_UTILITY_SHEET"])
  }

  deinit {
    analysisTask?.cancel()
    analysisRefreshTask?.cancel()
    engineTombstoneTask?.cancel()
    if let memorySampler {
      Task { @MainActor in
        memorySampler.stop(reason: "deinit")
      }
    }
    Task { @MainActor [memoryPressurePolicy, persistence, syncCoordinator] in
      memoryPressurePolicy.stop()
      persistence.stop()
      syncCoordinator.stop()
    }
  }

  var boardMoves: [BoardMove] {
    cachedBoardMoves
  }

  var analysisSetupStones: [BoardSetupStone] {
    recognizedSetupStones ?? []
  }

  var nextColor: StoneColor {
    currentPly.isMultiple(of: 2) ? .black : .white
  }

  var visibleCandidates: [CandidateMove] {
    cachedVisibleCandidates
  }

  var visibleCandidateOverlays: [VisibleCandidateOverlay] {
    cachedVisibleCandidateOverlays
  }

  var chartAxisMaxPly: Int {
    max(1, mainLine.count, currentPly)
  }

  var currentChartPoint: ChartPoint? {
    guard let cached = cachedChartAnalysis(at: currentPly) else { return nil }
    return ChartPoint(ply: currentPly, winrate: cached.winrate, scoreMean: cached.scoreMean)
  }

  var chartPoints: [ChartPoint] {
    guard selectedEngine != .none else { return [] }
    let lastPly = mainLine.count
    var points: [ChartPoint] = []
    points.reserveCapacity(lastPly + 1)
    for ply in 0...lastPly {
      if let cached = cachedChartAnalysis(at: ply) {
        points.append(ChartPoint(ply: ply, winrate: cached.winrate, scoreMean: cached.scoreMean))
      }
    }
    return points
  }

  var variationTree: VariationTree {
    variation.variationTree(qualityDelta: { [self] record in
      variationQualityDelta(for: record)
    })
  }

  private func resetVariationTree(from moves: [BoardMove], currentPly: Int) {
    variation.reset(from: moves, currentPly: currentPly)
  }

  private func makeVariationNodeID() -> String {
    variation.makeNodeID()
  }

  private func variationPathNodeIDs(to nodeID: String) -> [String] {
    variation.pathNodeIDs(to: nodeID)
  }

  private func variationMoves(to nodeID: String) -> [BoardMove] {
    variation.moves(to: nodeID)
  }

  private func variationPrimaryPathNodeIDs(from nodeID: String) -> [String] {
    variation.primaryPathNodeIDs(from: nodeID)
  }

  private func variationNodeID(onCurrentPathAt ply: Int) -> String {
    variation.nodeID(onCurrentPathAt: ply, mainLineCount: mainLine.count)
  }

  private func syncCurrentLine(to nodeID: String, includePrimaryContinuation: Bool = false) {
    variation.syncCurrentLine(
      to: nodeID,
      includePrimaryContinuation: includePrimaryContinuation,
      mainLine: &mainLine,
      currentPly: &currentPly
    )
  }

  private func appendVariationMove(_ move: BoardMove) -> String {
    let ply = (variation.records[variation.currentNodeID]?.ply ?? 0) + 1
    let nodeID = variation.appendMove(move, atPly: ply)
    syncCurrentLine(to: nodeID)
    return nodeID
  }

  private func variationQualityDelta(for record: QixiVariationModel.NodeRecord) -> Double? {
    guard let move = record.move, !move.isPass, let x = move.x, let y = move.y else { return nil }
    guard selectedEngine != .none else { return nil }
    if coreBackendService != nil {
      return variation.coreQualityDeltaByNodeID[record.id]
    }
    guard let parentID = record.parentID,
          let parentCache = cachedVariationAnalysis(for: parentID),
          let bestWinrate = Self.bestWinrate(in: parentCache.candidates) else {
      return nil
    }
    if let played = parentCache.candidates.first(where: { $0.x == x && $0.y == y }) {
      return (played.winrate - bestWinrate) * 100.0
    }
    guard let inferredWinrate = variationMoveWinrateFromAnalyzedChild(record: record, move: move) else {
      return nil
    }
    return (inferredWinrate - bestWinrate) * 100.0
  }

  private func cachedVariationAnalysis(for nodeID: String) -> QixiCachedAnalysis? {
    guard selectedEngine != .none else { return nil }
    return analysisCache.entry(
      engine: selectedEngine,
      cacheKey: positionCacheKey(
        engine: selectedEngine,
        moves: variationMoves(to: nodeID),
        setupStones: analysisSetupStones,
        komi: komi,
        rootNoise: rootNoise
      )
    )
  }

  private func variationMoveWinrateFromAnalyzedChild(
    record: QixiVariationModel.NodeRecord,
    move: BoardMove
  ) -> Double? {
    let childMoves = variationMoves(to: record.id)
    guard let childCache = cachedVariationAnalysis(for: record.id), childCache.visits > 0 else {
      return nil
    }
    let childNextPlayer = QixiBoardPosition.nextPlayer(after: childMoves)
    if childNextPlayer == move.color {
      return childCache.winrate
    }
    return 1.0 - childCache.winrate
  }

  private func cachedChartAnalysis(at ply: Int) -> QixiCachedAnalysis? {
    guard selectedEngine != .none, ply >= 0, ply <= mainLine.count else { return nil }
    let moves = Array(mainLine.prefix(ply))
    let key = positionCacheKey(
      engine: selectedEngine,
      moves: moves,
      setupStones: analysisSetupStones,
      komi: komi,
      rootNoise: rootNoise
    )
    return analysisCache.entry(engine: selectedEngine, cacheKey: key)
  }

  func selectEngine(_ engine: AnalysisEngine) {
    guard !isBackendInteractionBlocked else { return }
    let previousEngine = selectedEngine
    let transitionToken = beginBackendTransition(.switchingEngine)
    persistence.saveNow(reason: "beforeEngineSwitch")
    analysisTask?.cancel()
    selectedEngine = engine
    if let coreBackendService {
      hermesStatus = .loading
      persistence.saveNow(reason: engine == .none ? "engineNone" : "engineSelected")
      if engine == .none {
        submitCoreEngineSelection(engine, reason: "coreEngineUnloaded") { [weak self] success in
          guard let self else { return }
          self.finishBackendTransition(transitionToken)
          guard self.selectedEngine == .none else { return }
          if !success {
            let failure = self.lastEngineError
            self.selectedEngine = previousEngine
            self.persistence.saveNow(reason: "engineSelectionRolledBack")
            if previousEngine != .none {
              self.startCoreSnapshotPolling(
                engine: previousEngine,
                assumesEngineAlreadyLoaded: true,
                coreBackendService: coreBackendService,
                preservedEngineError: failure
              )
            }
            return
          }
          self.lastEngineError = nil
          self.hermesStatus = .ready
        }
      } else {
        startCoreSnapshotPolling(
          engine: engine,
          assumesEngineAlreadyLoaded: false,
          coreBackendService: coreBackendService,
          transitionToken: transitionToken,
          rollbackEngine: previousEngine
        )
      }
      return
    }
    if engine == .none {
      hermesStatus = .loading
      persistence.saveNow(reason: "engineNone")
      analysisTask = Task { [weak self, analysisService] in
        guard let self else { return }
        do {
          await self.waitForCoreMutationDrain()
          _ = try await analysisService.setEngine(.none)
          try Task.checkCancellation()
          self.finishBackendTransition(transitionToken)
          guard self.selectedEngine == .none else { return }
          self.lastEngineError = nil
          self.hermesStatus = .ready
          self.recordRuntimeDiagnostic(event: "engineUnloaded", success: true, message: "Selected engine none.")
        } catch {
          self.finishBackendTransition(transitionToken)
          guard !Task.isCancelled else { return }
          guard self.selectedEngine == .none else { return }
          let failure = self.localizedEngineError(error, fallbackKey: .engineErrorUnloadFailed)
          self.lastEngineError = failure
          self.hermesStatus = .offline
          self.recordRuntimeDiagnostic(event: "engineUnloadFailed", success: false, message: String(describing: error))
          self.selectedEngine = previousEngine
          self.persistence.saveNow(reason: "engineSelectionRolledBack")
          if previousEngine != .none {
            self.startAnalysis(
              engine: previousEngine,
              assumesEngineAlreadyLoaded: true,
              preservedEngineError: failure
            )
          }
        }
      }
      return
    }

    persistence.saveNow(reason: "engineSelected")
    recordRuntimeDiagnostic(event: "engineSelected", success: true, message: "Selected engine \(engine.rawValue).")
    startAnalysis(
      engine: engine,
      assumesEngineAlreadyLoaded: false,
      transitionToken: transitionToken,
      rollbackEngine: previousEngine
    )
  }

  private func startAnalysis(
    engine: AnalysisEngine,
    assumesEngineAlreadyLoaded: Bool,
    transitionToken: UInt64? = nil,
    rollbackEngine: AnalysisEngine? = nil,
    preservedEngineError: String? = nil
  ) {
    // Product path: core::MCTSStore only via NativeKataGoAnalysisService. No HTTP analyze loop.
    guard let coreBackendService else {
      finishBackendTransition(transitionToken)
      lastEngineError = L10n.text(.engineErrorLibraryNotLinked)
      hermesStatus = .offline
      recordRuntimeDiagnostic(
        event: "analysisUnavailable",
        success: false,
        message: "core backend service is required; HTTP bridge product path removed"
      )
      if let rollbackEngine, rollbackEngine != engine {
        selectedEngine = rollbackEngine
        persistence.saveNow(reason: "engineSelectionRolledBack")
      }
      return
    }
    startCoreSnapshotPolling(
      engine: engine,
      assumesEngineAlreadyLoaded: assumesEngineAlreadyLoaded,
      coreBackendService: coreBackendService,
      transitionToken: transitionToken,
      rollbackEngine: rollbackEngine,
      preservedEngineError: preservedEngineError
    )
  }

  private func startCoreSnapshotPolling(
    engine: AnalysisEngine,
    assumesEngineAlreadyLoaded: Bool,
    coreBackendService: any QixiCoreBackendService,
    transitionToken: UInt64? = nil,
    rollbackEngine: AnalysisEngine? = nil,
    preservedEngineError: String? = nil
  ) {
    analysisTask?.cancel()
    analysisGeneration += 1
    let generation = analysisGeneration
    if !assumesEngineAlreadyLoaded {
      hermesStatus = .loading
      submitCoreEngineSelection(engine, reason: "coreEngineSelected") { [weak self] success in
        guard let self else { return }
        self.finishBackendTransition(transitionToken)
        guard self.analysisGeneration == generation,
              self.selectedEngine == engine else { return }
        if !success {
          let failure = self.lastEngineError
          if let rollbackEngine {
            self.selectedEngine = rollbackEngine
            self.persistence.saveNow(reason: "engineSelectionRolledBack")
            if rollbackEngine != .none {
              self.startCoreSnapshotPolling(
                engine: rollbackEngine,
                assumesEngineAlreadyLoaded: true,
                coreBackendService: coreBackendService,
                preservedEngineError: failure
              )
            }
          }
          return
        }
        self.startCoreSnapshotPolling(
          engine: engine,
          assumesEngineAlreadyLoaded: true,
          coreBackendService: coreBackendService
        )
      }
      return
    }
    finishBackendTransition(transitionToken)
    analysisTask = Task { [weak self, coreBackendService] in
      guard let self else { return }
      do {
        var lastAppliedRevision: UInt64 = 0
        while true {
          try Task.checkCancellation()
          guard generation == analysisGeneration, selectedEngine == engine else { return }
          let result = try await coreBackendService.latestCoreSnapshot()
          try Task.checkCancellation()
          guard generation == analysisGeneration, selectedEngine == engine else { return }
          if result.revision != lastAppliedRevision {
            applyCoreBackendResult(result, reason: "snapshotPoll", allowWhileMutationsPending: false)
            if let preservedEngineError {
              lastEngineError = preservedEngineError
              hermesStatus = result.engineState == "ready" ? .ready : .offline
            }
            lastAppliedRevision = result.revision
          }
          try await Task.sleep(nanoseconds: 8_333_333)
        }
      } catch {
        guard !Task.isCancelled else { return }
        guard generation == analysisGeneration, selectedEngine == engine else { return }
        lastEngineError = localizedEngineError(error, fallbackKey: .engineErrorAnalysisFailed)
        hermesStatus = .offline
        recordRuntimeDiagnostic(event: "coreSnapshotPollingFailed", success: false, message: String(describing: error))
      }
    }
  }

  private static func nextRealtimeAnalysisTarget(after visits: Int, batch: Int) -> Int {
    let clampedVisits = max(0, min(QixiAnalysisLimits.maxMaxVisits, visits))
    guard clampedVisits < QixiAnalysisLimits.maxMaxVisits else {
      return QixiAnalysisLimits.maxMaxVisits
    }
    let clampedBatch = max(
      realtimeAnalysisMinimumVisitBatch,
      min(realtimeAnalysisMaximumVisitBatch, batch)
    )
    return min(QixiAnalysisLimits.maxMaxVisits, clampedVisits + clampedBatch)
  }

  private static func adjustedRealtimeAnalysisVisitBatch(
    currentBatch: Int,
    responseInterval: TimeInterval
  ) -> Int {
    let clampedBatch = max(
      realtimeAnalysisMinimumVisitBatch,
      min(realtimeAnalysisMaximumVisitBatch, currentBatch)
    )
    guard responseInterval.isFinite, responseInterval > 0 else {
      return clampedBatch
    }
    if responseInterval > realtimeAnalysisTargetResponseInterval * 1.55 {
      return max(realtimeAnalysisMinimumVisitBatch, clampedBatch / 2)
    }
    if responseInterval < realtimeAnalysisTargetResponseInterval * 0.55 {
      return min(realtimeAnalysisMaximumVisitBatch, clampedBatch * 2)
    }
    return clampedBatch
  }

  func step(by delta: Int) {
    guard !isBackendInteractionBlocked else { return }
    invalidateActiveAnalysisForPositionChange()
    currentPly = min(max(0, currentPly + delta), mainLine.count)
    variation.currentNodeID = variationNodeID(onCurrentPathAt: currentPly)
    clearBoardRecognitionPreview()
    if selectedEngine == .none {
      clearVisibleAnalysisAndRefreshAnchor()
    } else if !restoreCachedAnalysisForCurrentPosition() {
      clearVisibleAnalysisAndRefreshAnchor()
    }
    persistence.saveSoon(reason: "step")
    if coreBackendService != nil {
      if let target = variation.coreRootReferenceByNodeID[variation.currentNodeID] {
        submitCoreMutation(.jumpToNode(target, expectedBackendEpoch: 0), reason: "coreStep")
      } else {
        let steps = abs(delta)
        guard steps > 0 else { return }
        submitCoreMutation(
          delta < 0 ? .undo(steps: steps, expectedBackendEpoch: 0) : .redo(steps: steps, expectedBackendEpoch: 0),
          reason: "coreStep"
        )
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  func jump(to ply: Int) {
    guard !isBackendInteractionBlocked else { return }
    invalidateActiveAnalysisForPositionChange()
    currentPly = min(max(0, ply), mainLine.count)
    variation.currentNodeID = variationNodeID(onCurrentPathAt: currentPly)
    clearBoardRecognitionPreview()
    if selectedEngine == .none {
      clearVisibleAnalysisAndRefreshAnchor()
    } else if !restoreCachedAnalysisForCurrentPosition() {
      clearVisibleAnalysisAndRefreshAnchor()
    }
    persistence.saveSoon(reason: "jump")
    if coreBackendService != nil {
      if let target = variation.coreRootReferenceByNodeID[variation.currentNodeID] {
        submitCoreMutation(.jumpToNode(target, expectedBackendEpoch: 0), reason: "coreJump")
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  func jump(toVariationNode nodeID: String) {
    guard !isBackendInteractionBlocked else { return }
    guard variation.records[nodeID] != nil else { return }
    invalidateActiveAnalysisForPositionChange()
    syncCurrentLine(to: nodeID, includePrimaryContinuation: true)
    clearBoardRecognitionPreview()
    if selectedEngine == .none {
      clearVisibleAnalysisAndRefreshAnchor()
    } else if !restoreCachedAnalysisForCurrentPosition() {
      clearVisibleAnalysisAndRefreshAnchor()
    }
    persistence.saveSoon(reason: "variationJump")
    if coreBackendService != nil {
      if let target = variation.coreRootReferenceByNodeID[nodeID] {
        submitCoreMutation(.jumpToNode(target, expectedBackendEpoch: 0), reason: "coreVariationJump")
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  func passMove() {
    guard !isBackendInteractionBlocked else { return }
    invalidateActiveAnalysisForPositionChange()
    let parentVariationNodeID = variationNodeID(onCurrentPathAt: currentPly)
    let parentRoot = variation.coreRootReferenceByNodeID[parentVariationNodeID] ?? .node(coreCurrentRootID)
    let intentID = nextCoreIntentID()
    _ = appendVariationMove(BoardMove(pass: nextColor))
    let optimisticNodeID = variation.currentNodeID
    variation.coreRootReferenceByNodeID[optimisticNodeID] = .intent(intentID)
    clearBoardRecognitionPreview()
    persistence.saveSoon(reason: "passMove")
    if coreBackendService != nil {
      submitCoreMutation(
        .playMove(
          move: 361,
          uiIntentId: intentID,
          parentRoot: parentRoot,
          expectedBackendEpoch: 0
        ),
        reason: "corePassMove",
        optimisticVariationNodeID: optimisticNodeID,
        uiIntentID: intentID
      )
      return
    }
    requestAnalysisIfNeeded()
  }

  func play(at x: Int, y: Int) {
    guard !isBackendInteractionBlocked else { return }
    guard x >= 0, x < 19, y >= 0, y < 19 else { return }
    guard QixiBoardPosition.isLegalMove(
      after: boardMoves,
      setupStones: analysisSetupStones,
      x: x,
      y: y,
      color: nextColor
    ) else { return }
    invalidateActiveAnalysisForPositionChange()
    let parentVariationNodeID = variationNodeID(onCurrentPathAt: currentPly)
    let parentRoot = variation.coreRootReferenceByNodeID[parentVariationNodeID] ?? .node(coreCurrentRootID)
    let intentID = nextCoreIntentID()
    _ = appendVariationMove(BoardMove(color: nextColor, x: x, y: y))
    let optimisticNodeID = variation.currentNodeID
    variation.coreRootReferenceByNodeID[optimisticNodeID] = .intent(intentID)
    clearBoardRecognitionPreview()
    persistence.saveSoon(reason: "play")
    if coreBackendService != nil {
      submitCoreMutation(
        .playMove(
          move: coreMoveIndex(x: x, y: y),
          uiIntentId: intentID,
          parentRoot: parentRoot,
          expectedBackendEpoch: 0
        ),
        reason: "corePlay",
        optimisticVariationNodeID: optimisticNodeID,
        uiIntentID: intentID
      )
      return
    }
    requestAnalysisIfNeeded()
  }

  func candidateDelta(_ candidate: CandidateMove) -> Double {
    guard let best = bestCandidateWinrate else { return 0 }
    return (candidate.winrate - best) * 100.0
  }

  private func updateBoardMoveCache() {
    let boundedPly = min(max(0, currentPly), mainLine.count)
    cachedBoardMoves = Array(mainLine.prefix(boundedPly))
    let stones = QixiBoardPosition.visibleStones(
      after: cachedBoardMoves,
      setupStones: analysisSetupStones
    )
    visibleBoardStones = stones
    var colorsByID: [Int: StoneColor] = [:]
    colorsByID.reserveCapacity(stones.count)
    var occupiedIDs = Set<Int>()
    occupiedIDs.reserveCapacity(stones.count)
    for stone in stones {
      colorsByID[stone.id] = stone.color
      occupiedIDs.insert(stone.id)
    }
    visibleStoneColorsByID = colorsByID
    occupiedBoardPointIDs = occupiedIDs
    if boundedPly < mainLine.count {
      nextMoveCapturedBoardPointIDs = Set(
        QixiBoardPosition.capturedStoneIDsByPlaying(
          mainLine[boundedPly],
          after: cachedBoardMoves,
          setupStones: analysisSetupStones
        )
      )
    } else {
      nextMoveCapturedBoardPointIDs = []
    }
  }

  private static func bestWinrate(in candidates: [CandidateMove]) -> Double? {
    var best: Double?
    for candidate in candidates {
      if let currentBest = best {
        if candidate.winrate > currentBest {
          best = candidate.winrate
        }
      } else {
        best = candidate.winrate
      }
    }
    return best
  }

  private func updateCandidateCaches() {
    let best = Self.bestWinrate(in: candidates)
    let nextMoveOverlay = nextMoveOverlayContext()
    bestCandidateWinrate = best
    cachedVisibleCandidates = Self.visibleCandidates(
      from: candidates,
      bestWinrate: best,
      forcedPointID: (nextMoveOverlay?.childRootVisits ?? 0) > 0 ? nextMoveOverlay?.pointID : nil
    )
    cachedVisibleCandidateOverlays = Self.visibleCandidateOverlays(
      from: cachedVisibleCandidates,
      bestWinrate: best,
      nextMoveOverlay: nextMoveOverlay
    )
  }

  private func nextMoveOverlayContext() -> QixiNextMoveOverlayContext? {
    guard currentPly >= 0, currentPly < mainLine.count else { return nil }
    let move = mainLine[currentPly]
    guard !move.isPass, let x = move.x, let y = move.y else { return nil }
    let childRootCache: QixiCachedAnalysis?
    if selectedEngine == .none {
      childRootCache = nil
    } else {
      var childMoves = boardMoves
      childMoves.append(move)
      childRootCache = analysisCache.entry(
        engine: selectedEngine,
        cacheKey: positionCacheKey(
          engine: selectedEngine,
          moves: childMoves,
          setupStones: analysisSetupStones,
          komi: komi,
          rootNoise: rootNoise
        )
      )
    }
    return QixiNextMoveOverlayContext(
      x: x,
      y: y,
      color: move.color,
      childRootVisits: max(0, childRootCache?.visits ?? 0),
      childRootCache: childRootCache
    )
  }

  private static func visibleCandidates(
    from candidates: [CandidateMove],
    bestWinrate: Double?,
    forcedPointID: Int? = nil
  ) -> [CandidateMove] {
    guard let bestWinrate else { return [] }
    var visible = candidates
      .sorted { $0.rank < $1.rank }
      .prefix(10)
      .filter { ($0.winrate - bestWinrate) * 100.0 > -5.0 }
    if let forcedPointID,
       !visible.contains(where: { $0.id == forcedPointID }),
       let forced = candidates.sorted(by: { $0.rank < $1.rank }).first(where: { $0.id == forcedPointID }) {
      visible.append(forced)
      visible.sort { $0.rank < $1.rank }
    }
    return visible
  }

  private static func visibleCandidateOverlays(
    from visibleCandidates: [CandidateMove],
    bestWinrate: Double?,
    nextMoveOverlay: QixiNextMoveOverlayContext? = nil
  ) -> [VisibleCandidateOverlay] {
    var overlays: [VisibleCandidateOverlay] = []
    overlays.reserveCapacity(visibleCandidates.count + (nextMoveOverlay == nil ? 0 : 1))
    if let bestWinrate {
      for candidate in visibleCandidates {
        let delta = (candidate.winrate - bestWinrate) * 100.0
        overlays.append(
          VisibleCandidateOverlay(
            x: candidate.x,
            y: candidate.y,
            rankText: String(candidate.rank),
            winrateText: NumberText.winrate(candidate.winrate),
            visitsText: String(candidate.visits),
            scoreText: NumberText.score(candidate.scoreMean),
            colorComponents: CandidatePalette.components(deltaPercent: delta)
          )
        )
      }
    }
    if let nextMoveOverlay {
      if nextMoveOverlay.childRootVisits <= 0 {
        overlays.removeAll { $0.id == nextMoveOverlay.pointID }
        overlays.append(
          VisibleCandidateOverlay(
            x: nextMoveOverlay.x,
            y: nextMoveOverlay.y,
            rankText: "",
            winrateText: "",
            visitsText: "",
            scoreText: "",
            colorComponents: nil,
            continuationRingColor: nextMoveOverlay.color,
            showsAnalysisText: false,
            usesStoneSizedContinuationMarker: true
          )
        )
      } else if overlays.contains(where: { $0.id == nextMoveOverlay.pointID }) {
        // Already visible as a current-root candidate; analyzed continuations do not get a stone-color ring.
      } else if let childRootCache = nextMoveOverlay.childRootCache {
        overlays.append(
          VisibleCandidateOverlay(
            x: nextMoveOverlay.x,
            y: nextMoveOverlay.y,
            rankText: ">",
            winrateText: NumberText.winrate(childRootCache.winrate),
            visitsText: String(childRootCache.visits),
            scoreText: NumberText.score(childRootCache.scoreMean),
            colorComponents: CandidatePalette.unknownAnalysisComponents
          )
        )
      }
    }
    return overlays
  }

  func rootQualityDelta(for ply: Int) -> Double {
    if ply == currentPly { return 0.0 }
    let distance = abs(ply - currentPly)
    return -Double(min(24, distance * 2))
  }

  private func requestAnalysisIfNeeded(
    assumesEngineAlreadyLoaded: Bool = true
  ) {
    guard selectedEngine != .none else {
      persistence.saveSoon(reason: "analysisDisabled")
      return
    }
    startAnalysis(
      engine: selectedEngine,
      assumesEngineAlreadyLoaded: assumesEngineAlreadyLoaded
    )
  }

  private func submitCoreMutation(
    _ request: QixiCoreRequest,
    reason: String,
    optimisticVariationNodeID: String? = nil,
    uiIntentID: UInt64? = nil,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    guard coreBackendService != nil else {
      completion?(false)
      requestAnalysisIfNeeded()
      return
    }
    coreMutationQueue.enqueueRequest(
      request,
      reason: reason,
      host: self,
      optimisticVariationNodeID: optimisticVariationNodeID,
      uiIntentID: uiIntentID,
      completion: completion
    )
  }

  private func submitCoreEngineSelection(
    _ engine: AnalysisEngine,
    reason: String,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    guard coreBackendService != nil else {
      completion?(false)
      return
    }
    coreMutationQueue.enqueueEngineSelection(engine, reason: reason, host: self, completion: completion)
  }

  private func submitCoreMutationAndWait(
    _ request: QixiCoreRequest,
    reason: String
  ) async throws {
    do {
      try await coreMutationQueue.submitAndWait(request, reason: reason, host: self)
    } catch {
      throw QixiCoreBarrierError(operation: reason, backendMessage: lastEngineError)
    }
  }

  private func submitCoreEngineSelectionAndWait(
    _ engine: AnalysisEngine,
    reason: String
  ) async throws {
    do {
      try await coreMutationQueue.selectEngineAndWait(engine, reason: reason, host: self)
    } catch {
      throw QixiCoreBarrierError(operation: reason, backendMessage: lastEngineError)
    }
  }

  func noteCoreMutationCommittedIntent(
    uiIntentID: UInt64,
    optimisticVariationNodeID: String,
    result: QixiCoreBackendResult
  ) {
    variation.coreRootReferenceByNodeID[optimisticVariationNodeID] = result.snapshot.map {
      .lineage($0.rootLineageHash)
    } ?? .node(result.currentRoot)
  }

  func noteCoreMutationSucceeded(reason: String) {
    persistence.saveSoon(reason: reason)
  }

  func recordCoreRuntimeDiagnostic(event: String, success: Bool, message: String) {
    recordRuntimeDiagnostic(event: event, success: success, message: message)
  }

  func recoverFromCoreMutationFailure(
    message: String,
    abandoned: [QixiPendingCoreMutation]
  ) async {
    for pending in abandoned {
      pending.completion?(false)
    }
    lastEngineError = message
    hermesStatus = .offline
    recordRuntimeDiagnostic(event: "coreMutationFailed", success: false, message: message)
    if let coreBackendService,
       let result = try? await coreBackendService.latestCoreSnapshot() {
      applyCoreBackendResult(result, reason: "coreMutationRollback", allowWhileMutationsPending: true)
      lastEngineError = message
      hermesStatus = result.engineState == "ready" || result.engineState == "none" ? .ready : .offline
    }
  }

  func saveNow(reason: String = "manual") {
    persistence.saveNow(reason: reason)
  }

  func saveSoon(reason: String) {
    persistence.saveSoon(reason: reason)
  }

  func handleLifecycleTombstone(reason: String) {
    memorySampler?.recordLifecycle(reason: reason)
    persistence.handleLifecycleTombstone(reason: reason)
  }

  func handleLifecycleForeground() {
    // Blocking chrome + core enterForeground are submitted via the host callback.
    persistence.handleLifecycleForeground()
  }

  // MARK: - QixiPersistenceHost

  var hasCoreBackend: Bool { coreBackendService != nil }

  func notePersistenceError(_ message: String?) {
    lastSaveError = message
  }

  func noteSyncResult(_ result: QixiSyncResult) {
    let didUseICloud = QixiSyncStore.persistedICloudEnabled(afterSyncWith: result.provider)
    setICloudSyncEnabled(didUseICloud)
    syncStatus = QixiSyncStatus(
      provider: result.provider,
      lastSyncAt: didUseICloud ? Date() : nil,
      lastError: didUseICloud ? nil : L10n.text(.syncErrorMessage)
    )
  }

  func noteSyncMirrorFailure(_ message: String) {
    syncStatus = QixiSyncStatus(
      provider: syncStatus.provider,
      lastSyncAt: syncStatus.lastSyncAt,
      lastError: message
    )
  }

  func applyImportedAppSnapshot(_ snapshot: QixiAppSnapshot) {
    apply(snapshot: snapshot)
    resumeAnalysisForImportedSnapshotIfNeeded()
  }

  func submitCoreAutosaveTick(reason: String) {
    submitCoreMutation(
      .autosaveTick(reason: reason, expectedBackendEpoch: 0),
      reason: "corePeriodicAutosave"
    )
  }

  func submitCoreEnterBackground(deadlineMs: UInt32, completion: @escaping @MainActor (Bool) -> Void) {
    submitCoreMutation(
      .enterBackground(deadlineMs: deadlineMs, expectedBackendEpoch: 0),
      reason: "coreLifecycleCheckpoint",
      completion: completion
    )
  }

  func submitCoreEnterForeground(completion: @escaping @MainActor (Bool) -> Void) {
    let transitionToken = beginBackendTransition(.restoringState)
    submitCoreMutation(
      .enterForeground(expectedBackendEpoch: 0),
      reason: "coreLifecycleForeground",
      completion: { [weak self] ok in
        self?.finishBackendTransition(transitionToken)
        completion(ok)
      }
    )
  }

  @discardableResult
  private func handleAutomationLifecycleTombstoneIfNeeded(
    environment: [String: String],
    arguments: [String]
  ) -> Bool {
    guard let reason = Self.automationLifecycleTombstoneReason(
      environment: environment,
      arguments: arguments
    ) else { return false }
    handleLifecycleTombstone(reason: reason)
    return true
  }

  private static func automationLifecycleTombstoneReason(
    environment: [String: String],
    arguments: [String]
  ) -> String? {
    if let reason = environment["QIXI_LIFECYCLE_TOMBSTONE_ON_LAUNCH"], !reason.isEmpty {
      return reason
    }
    guard let flagIndex = arguments.firstIndex(of: "--qixi-lifecycle-tombstone-on-launch") else {
      return nil
    }
    let valueIndex = arguments.index(after: flagIndex)
    guard valueIndex < arguments.endIndex else { return nil }
    let reason = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    return reason.isEmpty ? nil : reason
  }

  func syncNow() {
    syncCoordinator.syncNow()
  }

  // MARK: - Feature hosts (utility sheets)

  var mainLineCount: Int { mainLine.count }

  func resumeAnalysisAfterImportedSnapshot() {
    resumeAnalysisForImportedSnapshotIfNeeded()
  }

  func mirrorVisibleMCTSStatePackageAfterManualSync(result: QixiSyncResult) async throws {
    try await mirrorVisibleMCTSStatePackageToICloudIfNeeded(
      result: result,
      reason: "manualSyncMCTSStatePackage"
    )
  }

  func setLanguage(_ language: AppLanguage) {
    self.language = language
    UserDefaults.standard.set(language.rawValue, forKey: QixiPreferences.languageKey)
  }

  func completeOnboarding(enableICloud: Bool) {
    onboardingCompleted = true
    UserDefaults.standard.set(true, forKey: QixiPreferences.onboardingCompletedKey)
    if enableICloud {
      Task { [weak self] in
        guard let self else { return }
        while self.isBackendInteractionBlocked {
          try? await Task.sleep(nanoseconds: 10_000_000)
        }
        self.syncNow()
      }
    } else {
      setICloudSyncEnabled(false)
      persistence.saveNow(reason: "onboardingCompleted")
    }
  }

  func skipICloudOnboarding() {
    completeOnboarding(enableICloud: false)
  }

  func openUtilitySheet(_ sheet: QixiUtilitySheet) {
    guard !isBackendInteractionBlocked else { return }
    utilitySheet = sheet
  }

  func newGame() {
    guard !isBackendInteractionBlocked else { return }
    let transitionToken = beginBackendTransition(.exportingState)
    analysisTask?.cancel()
    analysisRefreshTask?.cancel()
    let snapshotToArchive = currentSnapshot(reason: "newGameMCTSStateArchive")
    Task { [weak self] in
      guard let self else { return }
      defer { self.finishBackendTransition(transitionToken) }
      await archiveCurrentMCTSStateBeforeReset(snapshotToArchive, reason: "newGameMCTSStateArchive")
      resetForNewGame()
    }
  }

  private func resetForNewGame() {
    invalidateActiveAnalysisForPositionChange()
    mainLine = []
    currentPly = 0
    resetVariationTree(from: mainLine, currentPly: currentPly)
    clearRecognizedSetup()
    clearVisibleAnalysisAndRefreshAnchor()
    analysisCache.clear()
    persistence.saveNow(reason: "newGame")
    if coreBackendService != nil {
      variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
      submitCoreMutation(.newGame(komi: komi, nextPla: .black, expectedBackendEpoch: 0), reason: "coreNewGame")
      return
    }
    requestAnalysisIfNeeded()
  }

  func importSGF(text: String) throws {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "SGF import", backendMessage: "another backend transition is active")
    }
    let importedMoves = try QixiSGFParser.parseValidatedMainLineMoves(from: text)
    invalidateActiveAnalysisForPositionChange()
    mainLine = importedMoves
    currentPly = importedMoves.count
    resetVariationTree(from: importedMoves, currentPly: currentPly)
    clearRecognizedSetup()
    clearVisibleAnalysis()
    analysisCache.clear()
    refreshLocalChartAnchor()
    persistence.saveNow(reason: "sgfImport")
    if coreBackendService != nil {
      variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
      submitCoreMutation(
        .newGame(komi: komi, nextPla: importedMoves.first?.color ?? .black, expectedBackendEpoch: 0),
        reason: "coreSGFImportReset"
      )
      var parent: QixiCoreRootReference = .node(0)
      for (index, move) in importedMoves.enumerated() {
        let intentID = nextCoreIntentID()
        let nodeID = variation.currentPathNodeIDs[index + 1]
        variation.coreRootReferenceByNodeID[nodeID] = .intent(intentID)
        let coreMove = move.isPass
          ? 361
          : coreMoveIndex(x: move.x ?? -1, y: move.y ?? -1)
        submitCoreMutation(
          .playMove(
            move: coreMove,
            uiIntentId: intentID,
            parentRoot: parent,
            expectedBackendEpoch: 0
          ),
          reason: "coreSGFImportMove",
          optimisticVariationNodeID: nodeID,
          uiIntentID: intentID
        )
        parent = .intent(intentID)
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  func prepareMCTSStateExportPackage() async throws -> URL {
    persistence.cancelPendingSave()
    let snapshot = currentSnapshot(reason: "manualMCTSStateExport")
    persistence.saveNow(reason: "manualMCTSStateExport")
    let packageURL = try await makeMCTSStatePackage(snapshot: snapshot, reason: "manualMCTSStateExport")
    lastSaveError = nil
    return packageURL
  }

  private func mirrorVisibleMCTSStatePackageToICloudIfNeeded(
    result: QixiSyncResult,
    reason: String
  ) async throws {
    guard result.provider == .iCloud else { return }
    let snapshot = currentSnapshot(reason: reason)
    _ = try await mirrorVisibleMCTSStatePackage(snapshot: snapshot, reason: reason)
  }

  private func archiveCurrentMCTSStateBeforeReset(
    _ snapshot: QixiAppSnapshot,
    reason: String
  ) async {
    guard shouldArchiveMCTSStateBeforeReset(snapshot) else { return }
    do {
      _ = try await mirrorVisibleMCTSStatePackage(snapshot: snapshot, reason: reason)
      lastSaveError = nil
    } catch {
      lastSaveError = String(describing: error)
    }
  }

  private func shouldArchiveMCTSStateBeforeReset(_ snapshot: QixiAppSnapshot) -> Bool {
    !snapshot.mainLine.isEmpty ||
      !(snapshot.recognizedSetupStones ?? []).isEmpty ||
      snapshot.analysisByEngine.values.contains { !$0.isEmpty }
  }

  @discardableResult
  private func mirrorVisibleMCTSStatePackage(
    snapshot: QixiAppSnapshot,
    reason: String
  ) async throws -> URL {
    let packageURL = try await makeMCTSStatePackage(snapshot: snapshot, reason: reason)
    defer {
      try? FileManager.default.removeItem(at: packageURL)
    }
    return try QixiSyncStore.replaceVisibleMCTSStatePackage(with: packageURL)
  }

  private func makeMCTSStatePackage(snapshot: QixiAppSnapshot, reason: String) async throws -> URL {
    let transitionToken = beginBackendTransition(.exportingState)
    startIoProgressPolling(for: transitionToken)
    defer { finishBackendTransition(transitionToken) }
    await Task.yield()
    var packageSnapshot = snapshot
    if coreBackendService != nil {
      await waitForCoreMutationDrain()
      packageSnapshot = currentSnapshot(reason: reason)
    }
    let packageURL = try QixiMCTSStatePackageStore.freshTemporaryPackageURL()
    do {
      updateBackendTransitionProgress(transitionToken, phase: "Writing snapshot", fraction: 0.1)
      try QixiMCTSStatePackageStore.writeSnapshot(packageSnapshot, to: packageURL)
      var includesEngineTombstone = false
      var includesCoreState = false
      if coreBackendService != nil {
        let coreStateURL = QixiMCTSStatePackageStore.coreStateURL(in: packageURL)
        updateBackendTransitionProgress(transitionToken, phase: "Serializing MCTS store", fraction: 0.25)
        try await submitCoreMutationAndWait(
          .exportAnalysisState(path: coreStateURL.path, expectedBackendEpoch: 0),
          reason: "coreMCTSStateExport"
        )
        includesCoreState = true
      } else if selectedEngine != .none,
                let engineTombstoneService = analysisService as? any QixiEngineTombstoneService {
        try await engineTombstoneService.exportEngineTombstone(
          to: QixiMCTSStatePackageStore.engineTombstoneURL(in: packageURL)
        )
        try QixiEngineTombstoneStore.markExported(engine: selectedEngine, reason: reason)
        includesEngineTombstone = true
      }
      try QixiMCTSStatePackageStore.writeManifest(
        snapshot: packageSnapshot,
        includesEngineTombstone: includesEngineTombstone,
        includesCoreState: includesCoreState,
        to: packageURL
      )
      return packageURL
    } catch {
      try? FileManager.default.removeItem(at: packageURL)
      throw error
    }
  }

  private func waitForCoreMutationDrain() async {
    await coreMutationQueue.waitForDrain()
  }

  func importMCTSStatePackage(from packageURL: URL) async throws {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "MCTS state import", backendMessage: "another backend transition is active")
    }
    let transitionToken = beginBackendTransition(.importingState)
    startIoProgressPolling(for: transitionToken)
    defer { finishBackendTransition(transitionToken) }
    await Task.yield()
    analysisTask?.cancel()
    analysisRefreshTask?.cancel()
    await waitForCoreMutationDrain()
    updateBackendTransitionProgress(transitionToken, phase: "Reading package", fraction: 0.05)
    let imported = try QixiMCTSStatePackageStore.loadPackage(from: packageURL)
    if let coreStateURL = imported.coreStateURL {
      guard let coreBackendService else {
        throw QixiStrictJSONError.malformed(
          label: "Qixi MCTS state package",
          message: "contains core MCTS state but this build cannot restore it"
        )
      }
      hermesStatus = .loading
      let previousEngine = selectedEngine
      do {
        try await submitCoreEngineSelectionAndWait(.none, reason: "coreMCTSStateImportQuiesce")
        updateBackendTransitionProgress(transitionToken, phase: "Importing MCTS store", fraction: 0.25)
        try await submitCoreMutationAndWait(
          .importAnalysisState(path: coreStateURL.path, expectedBackendEpoch: 0),
          reason: "coreMCTSStateImport"
        )
      } catch {
        if previousEngine != .none {
          try? await submitCoreEngineSelectionAndWait(
            previousEngine,
            reason: "coreMCTSStateImportRollbackEngine"
          )
        }
        throw error
      }
      apply(snapshot: imported.snapshot)
      persistence.saveNow(reason: "mctsStateImport")
      try await submitCoreMutationAndWait(
        .setKomi(komi, expectedBackendEpoch: 0),
        reason: "coreMCTSStateImportKomi"
      )
      try await submitCoreMutationAndWait(
        .setWideRootNoise(rootNoise, expectedBackendEpoch: 0),
        reason: "coreMCTSStateImportRootNoise"
      )
      if imported.snapshot.selectedEngine != .none {
        do {
          try await submitCoreEngineSelectionAndWait(
            imported.snapshot.selectedEngine,
            reason: "coreMCTSStateImportEngine"
          )
        } catch {
          lastEngineError = localizedEngineError(error, fallbackKey: .engineErrorAnalysisFailed)
          hermesStatus = .offline
          lastSaveError = nil
          persistence.saveSoon(reason: "mctsStateImportEngineUnavailable")
          return
        }
      }
      let result = try await coreBackendService.latestCoreSnapshot()
      applyCoreBackendResult(result, reason: "coreMCTSStateImport", allowWhileMutationsPending: true)
      lastEngineError = nil
      lastSaveError = nil
      if selectedEngine != .none {
        startAnalysis(engine: selectedEngine, assumesEngineAlreadyLoaded: true)
      } else {
        hermesStatus = .ready
      }
      persistence.saveSoon(reason: "mctsStateImport")
      return
    }
    var didRestoreEngineTombstone = false
    if let tombstoneURL = imported.engineTombstoneURL {
      guard let engineTombstoneService = analysisService as? any QixiEngineTombstoneService else {
        throw QixiStrictJSONError.malformed(
          label: "Qixi MCTS state package",
          message: "contains native MCTS state but this build cannot restore it"
        )
      }
      hermesStatus = .loading
      try await engineTombstoneService.restoreEngineTombstone(from: tombstoneURL, for: imported.snapshot.selectedEngine)
      try QixiEngineTombstoneStore.markRestored(engine: imported.snapshot.selectedEngine)
      try await engineTombstoneService.exportEngineTombstone(to: QixiEngineTombstoneStore.tombstoneURL)
      try QixiEngineTombstoneStore.markExported(engine: imported.snapshot.selectedEngine, reason: "manualMCTSStateImport")
      didRestoreEngineTombstone = true
    }
    apply(snapshot: imported.snapshot)
    persistence.saveNow(reason: "mctsStateImport")

    if didRestoreEngineTombstone {
      lastEngineError = nil
      lastSaveError = nil
      hermesStatus = .ready
      if selectedEngine != .none {
        startAnalysis(engine: selectedEngine, assumesEngineAlreadyLoaded: true)
      }
    } else {
      lastSaveError = nil
      resumeAnalysisForImportedSnapshotIfNeeded()
    }
    persistence.saveSoon(reason: "mctsStateImport")
  }

  func installNativeModel(from url: URL) async throws -> NativeKataGoInstalledModel {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "model installation", backendMessage: "another backend transition is active")
    }
    let transitionToken = beginBackendTransition(.installingModel)
    defer { finishBackendTransition(transitionToken) }
    await Task.yield()
    var replacingSelectedEngine: AnalysisEngine?
    var didUnloadSelectedEngine = false
    do {
      let installer = try QixiNativeModelInstaller()
      let spec = try await Task.detached(priority: .userInitiated) {
        try installer.recognizedModelSpec(for: url)
      }.value
      let wasReplacingSelectedEngine = selectedEngine == spec.engine
      if wasReplacingSelectedEngine {
        replacingSelectedEngine = spec.engine
        try await unloadSelectedEngineForModelInstall(spec.engine)
        didUnloadSelectedEngine = true
      }
      let installed = try await Task.detached(priority: .userInitiated) {
        try installer.installVerifiedModel(from: url, spec: spec)
      }.value
      lastEngineError = nil
      reloadInstalledModelIfNeeded(engine: installed.resolvedModel.spec.engine, wasReplacingSelectedEngine: wasReplacingSelectedEngine)
      return installed
    } catch {
      lastEngineError = localizedEngineError(error, fallbackKey: .engineErrorModelInstallFailed)
      recoverAfterModelInstallFailure(
        replacingEngine: replacingSelectedEngine,
        didUnloadSelectedEngine: didUnloadSelectedEngine
      )
      throw error
    }
  }

  func installNativeCoreMLPackage(from url: URL) async throws -> NativeKataGoInstalledCoreMLPackage {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "Core ML package installation", backendMessage: "another backend transition is active")
    }
    let transitionToken = beginBackendTransition(.installingModel)
    defer { finishBackendTransition(transitionToken) }
    await Task.yield()
    var replacingSelectedEngine: AnalysisEngine?
    var didUnloadSelectedEngine = false
    do {
      let installer = try QixiNativeModelInstaller()
      let match = try await Task.detached(priority: .userInitiated) {
        try installer.recognizedCoreMLPackageMatch(for: url)
      }.value
      let wasReplacingSelectedEngine = selectedEngine == match.modelSpec.engine
      if wasReplacingSelectedEngine {
        replacingSelectedEngine = match.modelSpec.engine
        try await unloadSelectedEngineForModelInstall(match.modelSpec.engine)
        didUnloadSelectedEngine = true
      }
      let installed = try await Task.detached(priority: .userInitiated) {
        try installer.installVerifiedCoreMLPackage(from: url, match: match)
      }.value
      lastEngineError = nil
      reloadInstalledModelIfNeeded(engine: installed.modelSpec.engine, wasReplacingSelectedEngine: wasReplacingSelectedEngine)
      return installed
    } catch {
      lastEngineError = localizedEngineError(error, fallbackKey: .engineErrorModelInstallFailed)
      recoverAfterModelInstallFailure(
        replacingEngine: replacingSelectedEngine,
        didUnloadSelectedEngine: didUnloadSelectedEngine
      )
      throw error
    }
  }

  private func unloadSelectedEngineForModelInstall(_ engine: AnalysisEngine) async throws {
    analysisTask?.cancel()
    selectedEngine = .none
    clearVisibleAnalysisAndRefreshAnchor()
    hermesStatus = .loading
    persistence.saveNow(reason: "beforeModelInstall")
    if coreBackendService != nil {
      try await submitCoreEngineSelectionAndWait(.none, reason: "coreModelInstallUnload")
    } else {
      await waitForCoreMutationDrain()
      _ = try await analysisService.setEngine(.none)
    }
  }

  private func recoverAfterModelInstallFailure(
    replacingEngine engine: AnalysisEngine?,
    didUnloadSelectedEngine: Bool
  ) {
    guard let engine else { return }
    selectedEngine = engine
    persistence.saveNow(reason: "modelInstallFailed")
    if didUnloadSelectedEngine {
      let transitionToken = beginBackendTransition(.switchingEngine)
      startAnalysis(
        engine: engine,
        assumesEngineAlreadyLoaded: false,
        transitionToken: transitionToken
      )
    } else {
      hermesStatus = .offline
    }
  }

  private func reloadInstalledModelIfNeeded(engine: AnalysisEngine, wasReplacingSelectedEngine: Bool) {
    if wasReplacingSelectedEngine && selectedEngine == .none {
      selectedEngine = engine
      let transitionToken = beginBackendTransition(.switchingEngine)
      startAnalysis(
        engine: engine,
        assumesEngineAlreadyLoaded: false,
        transitionToken: transitionToken
      )
    } else if selectedEngine == engine {
      let transitionToken = beginBackendTransition(.switchingEngine)
      startAnalysis(
        engine: engine,
        assumesEngineAlreadyLoaded: false,
        transitionToken: transitionToken
      )
    }
  }

  func recognizeBoardImage(data: Data) throws -> QixiBoardRecognitionResult {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "board recognition", backendMessage: "another backend transition is active")
    }
    let result = try QixiBoardImageRecognizer.recognizeBoard(from: data)
    applyBoardRecognition(result)
    return result
  }

  func recognizeBoardImage(url: URL) throws -> QixiBoardRecognitionResult {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "board recognition", backendMessage: "another backend transition is active")
    }
    let result = try QixiBoardImageRecognizer.recognizeBoard(from: url)
    applyBoardRecognition(result)
    return result
  }

  func applyBoardRecognition(_ result: QixiBoardRecognitionResult) {
    guard !isBackendInteractionBlocked else { return }
    let stones = Self.normalizedRecognizedStones(result.stones)
    let appliedResult = QixiBoardRecognitionResult(stones: stones, gridX: result.gridX, gridY: result.gridY)
    let setupStones = Self.setupStones(from: stones)
    invalidateActiveAnalysisForPositionChange()
    lastBoardRecognition = appliedResult
    recognizedSetupStones = setupStones
    mainLine = []
    currentPly = 0
    resetVariationTree(from: mainLine, currentPly: currentPly)
    updateBoardMoveCache()
    clearVisibleAnalysisAndRefreshAnchor()
    persistence.saveSoon(reason: "boardRecognitionApplied")
    if coreBackendService != nil {
      variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
      submitCoreMutation(
        .applyRecognizedBoard(
          setupStones: setupStones,
          nextPla: .black,
          expectedBackendEpoch: 0
        ),
        reason: "coreBoardRecognitionApplied"
      )
      return
    }
    requestAnalysisIfNeeded()
  }

  @discardableResult
  func exportCurrentRealDeviceEvidence(
    device: QixiRealDeviceEvidence.Device,
    backend: QixiRealDeviceEvidence.Backend?,
    measurements: QixiRealDeviceEvidence.Measurements,
    lifecycle: QixiRealDeviceEvidence.Lifecycle,
    features: QixiRealDeviceEvidence.Features,
    artifacts: [QixiRealDeviceEvidence.Artifact],
    autoWriteDeviceLogArtifactPath: String? = nil,
    to url: URL = QixiRealDeviceEvidenceStore.evidenceURL,
    runId: String = UUID().uuidString.lowercased(),
    recordedAt: Date = Date()
  ) throws -> URL {
    try validateRealDeviceEvidenceBackendInput(backend)
    guard let cachedAnalysis = currentCachedAnalysisForEvidence() else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Real-device evidence requires cached analysis for the current root."
      )
    }
    let nativeEngineEvidence = try nativeEngineEvidenceForCurrentSelection(recordedAt: recordedAt)
    var evidence = QixiRealDeviceEvidence(
      runId: runId,
      recordedAt: recordedAt,
      device: device,
      app: QixiRealDeviceEvidence.App.current(analysisRuntime: analysisService.runtime.rawValue),
      backend: backend,
      analysis: QixiRealDeviceEvidenceStore.analysisEvidence(
        engine: selectedEngine,
        cachedAnalysis: cachedAnalysis,
        komi: komi,
        rootNoise: rootNoise,
        nativeEngine: nativeEngineEvidence
      ),
      measurements: measurements,
      lifecycle: lifecycle,
      features: features,
      artifacts: artifacts
    )
    if let autoWriteDeviceLogArtifactPath {
      let deviceLogArtifact = try QixiRealDeviceEvidenceStore.writeDeviceLogArtifact(
        for: evidence,
        path: autoWriteDeviceLogArtifactPath,
        evidenceURL: url
      )
      evidence.artifacts.removeAll { $0.kind == "device-log" }
      evidence.artifacts.append(deviceLogArtifact)
    }
    try QixiRealDeviceEvidenceStore.save(evidence, to: url)
    return url
  }

  private func apply(
    _ response: AnalysisResponse,
    engine: AnalysisEngine,
    cacheKey: String,
    recordDiagnostic: Bool = true,
    scheduleSave: Bool = true
  ) throws -> Bool {
    try QixiAnalysisResponseValidator.validate(response, expectedEngine: engine)
    guard response.positionKey == cacheKey else {
      if recordDiagnostic {
        recordRuntimeDiagnostic(
          event: "analysisSkippedStalePosition",
          success: false,
          message: "responsePositionKey did not match current cacheKey"
        )
      }
      return false
    }
    guard currentAnalysisCacheKey(for: engine) == cacheKey else {
      if recordDiagnostic {
        recordRuntimeDiagnostic(
          event: "analysisSkippedInactiveRoot",
          success: false,
          message: "response matched request cacheKey but no longer matches the visible root"
        )
      }
      return false
    }
    if let regression = analysisRegressionReason(response, engine: engine, cacheKey: cacheKey) {
      if recordDiagnostic {
        recordRuntimeDiagnostic(
          event: "analysisSkippedRegressiveVisits",
          success: false,
          message: regression
        )
      }
      return false
    }
    if let incomplete = incompleteCandidatePacketReason(response, engine: engine, cacheKey: cacheKey) {
      if recordDiagnostic {
        recordRuntimeDiagnostic(
          event: "analysisSkippedIncompleteCandidates",
          success: false,
          message: incomplete
        )
      }
      return false
    }
    if let winrate = response.winrate { currentWinrate = winrate }
    if let score = response.scoreMean { currentScoreMean = score }
    candidates = response.moves.enumerated().compactMap { offset, move in
      guard let winrate = move.winrate else { return nil }
      return CandidateMove(
        x: move.x,
        y: move.y,
        rank: offset + 1,
        winrate: winrate,
        visits: move.visits ?? 0,
        scoreMean: move.scoreMean ?? response.scoreMean ?? 0.0
      )
    }
    territory = response.ownership.enumerated().compactMap { index, value in
      guard abs(value) >= 0.16 else { return nil }
      return TerritoryPoint(x: index % 19, y: index / 19, ownership: value)
    }
    cacheCurrentAnalysis(
      engine: engine,
      cacheKey: cacheKey,
      positionKey: cacheKey,
      visits: responseRootVisits(response)
    )
    if recordDiagnostic {
      recordRuntimeDiagnostic(
        event: "analysisApplied",
        success: true,
        message: "visits=\(response.visits ?? 0) candidates=\(candidates.count)"
      )
    }
    exportAutomationRealDeviceEvidenceIfRequested(
      environment: ProcessInfo.processInfo.environment,
      trigger: .analysis
    )
    if scheduleSave {
      persistence.saveSoon(reason: "analysisApplied")
    }
    return true
  }

  func applyCoreBackendResult(
    _ result: QixiCoreBackendResult,
    reason: String,
    allowWhileMutationsPending: Bool
  ) {
    if result.backendEpoch < coreBackendEpoch ||
       (result.backendEpoch == coreBackendEpoch && result.revision < coreRevision) {
      return
    }
    let deferSnapshot = !allowWhileMutationsPending && coreMutationQueue.pendingCount > 0
    coreBackendEpoch = result.backendEpoch
    coreRevision = result.revision
    coreCurrentRootID = result.currentRoot
    if result.ok {
      lastEngineError = nil
      hermesStatus = selectedEngine == .none || result.engineState == "ready" ? .ready : .loading
    } else {
      lastEngineError = result.message
      hermesStatus = result.engineState == "loading" ? .loading : .offline
      recordRuntimeDiagnostic(event: "coreBackendRequestFailed", success: false, message: result.message)
      return
    }
    if deferSnapshot { return }
    guard let snapshot = result.snapshot else { return }
    applyCoreSnapshot(snapshot, reason: reason)
  }

  private func applyCoreSnapshot(_ snapshot: QixiCoreSnapshot, reason: String) {
    coreCurrentRootID = snapshot.root
    currentWinrate = snapshot.rootVisits > 0 ? snapshot.rootWinrate : 0.5
    currentScoreMean = snapshot.rootVisits > 0 ? snapshot.rootScoreMean : 0.0
    candidates = snapshot.candidates.enumerated().compactMap { offset, candidate in
      guard !candidate.pass,
            candidate.x >= 0, candidate.x < 19,
            candidate.y >= 0, candidate.y < 19 else {
        return nil
      }
      return CandidateMove(
        x: candidate.x,
        y: candidate.y,
        rank: offset + 1,
        winrate: candidate.winrate,
        visits: Int(clamping: candidate.visits),
        scoreMean: candidate.scoreMean
      )
    }
    if snapshot.hasOwnership {
      territory = snapshot.ownership.enumerated().compactMap { index, value in
        guard abs(value) >= 0.16 else { return nil }
        return TerritoryPoint(x: index % 19, y: index / 19, ownership: value)
      }
    }
    rebuildVariationTree(from: snapshot)
    if selectedEngine != .none, let cacheKey = currentAnalysisCacheKey(for: selectedEngine) {
      cacheCurrentAnalysis(
        engine: selectedEngine,
        cacheKey: cacheKey,
        positionKey: cacheKey,
        visits: Int(clamping: snapshot.rootVisits)
      )
    }
    if reason != "snapshotPoll" || snapshot.rootVisits.isMultiple(of: 64) {
      recordRuntimeDiagnostic(
        event: "coreSnapshotApplied",
        success: true,
        message: "root=\(snapshot.root) visits=\(snapshot.rootVisits) candidates=\(snapshot.candidates.count)"
      )
    }
  }

  private func rebuildVariationTree(from snapshot: QixiCoreSnapshot) {
    _ = variation.apply(from: snapshot, boardMove: { move, color in
      boardMove(fromCoreMove: move, color: color)
    })
    let newMainLine = variation.currentPathNodeIDs.compactMap { variation.records[$0]?.move }
    let newPly = min(variation.records[variation.currentNodeID]?.ply ?? 0, newMainLine.count)
    // Avoid @Published churn / board cache rebuild when the path is unchanged.
    if newMainLine != mainLine {
      mainLine = newMainLine
    }
    if newPly != currentPly {
      currentPly = newPly
    }
  }

  private func coreVariationNodeID(_ lineageHash: UInt64) -> String {
    "l\(lineageHash)"
  }

  private func boardMove(fromCoreMove move: Int, color: String) -> BoardMove? {
    let stoneColor: StoneColor
    if color == "black" {
      stoneColor = .black
    } else if color == "white" {
      stoneColor = .white
    } else {
      return nil
    }
    if move == 361 {
      return BoardMove(pass: stoneColor)
    }
    guard move >= 0, move < 361 else { return nil }
    return BoardMove(color: stoneColor, x: move % 19, y: move / 19)
  }

  private func analysisRegressionReason(
    _ response: AnalysisResponse,
    engine: AnalysisEngine,
    cacheKey: String
  ) -> String? {
    guard let cached = analysisCache.entry(engine: engine, cacheKey: cacheKey) else { return nil }
    let incomingRootVisits = responseRootVisits(response)
    if incomingRootVisits < cached.visits {
      return "root visits regressed incoming=\(incomingRootVisits) cached=\(cached.visits)"
    }
    if response.moves.count < cached.candidates.count {
      return "candidate list shrank incoming=\(response.moves.count) cached=\(cached.candidates.count)"
    }

    var cachedVisitsByPoint: [Int: Int] = [:]
    cachedVisitsByPoint.reserveCapacity(cached.candidates.count)
    for candidate in cached.candidates {
      cachedVisitsByPoint[boardPointID(x: candidate.x, y: candidate.y)] = max(
        cachedVisitsByPoint[boardPointID(x: candidate.x, y: candidate.y)] ?? 0,
        candidate.visits
      )
    }
    for move in response.moves {
      let pointID = boardPointID(x: move.x, y: move.y)
      guard let cachedVisits = cachedVisitsByPoint[pointID] else { continue }
      let incomingVisits = max(0, move.visits ?? 0)
      if incomingVisits < cachedVisits {
        return "candidate \(move.x),\(move.y) visits regressed incoming=\(incomingVisits) cached=\(cachedVisits)"
      }
    }
    return nil
  }

  private func incompleteCandidatePacketReason(
    _ response: AnalysisResponse,
    engine: AnalysisEngine,
    cacheKey: String
  ) -> String? {
    guard analysisCache.entry(engine: engine, cacheKey: cacheKey) == nil else { return nil }
    let expectedCandidates = min(Self.realtimeAnalysisMinimumDisplayCandidates, legalMoveCountForCurrentRoot())
    guard expectedCandidates > 1 else { return nil }
    let incomingRootVisits = responseRootVisits(response)
    guard incomingRootVisits < Self.realtimeAnalysisMinimumDisplayVisits,
          response.moves.count < expectedCandidates else {
      return nil
    }
    return "early candidate packet incomplete visits=\(incomingRootVisits) candidates=\(response.moves.count) expected=\(expectedCandidates)"
  }

  private func legalMoveCountForCurrentRoot() -> Int {
    let color = nextColor
    var count = 1
    for y in 0..<QixiBoardPosition.boardSize {
      for x in 0..<QixiBoardPosition.boardSize {
        if QixiBoardPosition.isLegalMove(
          after: boardMoves,
          setupStones: analysisSetupStones,
          x: x,
          y: y,
          color: color
        ) {
          count += 1
        }
      }
    }
    return count
  }

  private func responseRootVisits(_ response: AnalysisResponse) -> Int {
    if let visits = response.visits {
      return max(0, visits)
    }
    return response.moves.reduce(0) { total, move in
      total + max(0, move.visits ?? 0)
    }
  }

  private func boardPointID(x: Int, y: Int) -> Int {
    y * 19 + x
  }

  private func nextCoreIntentID() -> UInt64 {
    coreMutationQueue.allocateIntentID()
  }

  private func coreMoveIndex(x: Int, y: Int) -> Int {
    y * 19 + x
  }

  private func refreshLocalChartAnchor() {
    currentWinrate = 0.5
    currentScoreMean = 0.0
  }

  private func clearVisibleAnalysis() {
    candidates = []
    territory = []
  }

  private func clearVisibleAnalysisAndRefreshAnchor() {
    clearVisibleAnalysis()
    refreshLocalChartAnchor()
  }

  private func resumeAnalysisAfterLaunch(transitionToken: UInt64) async {
    var transitionHandedToEngineLoad = false
    var coreBootSucceeded = false
    defer {
      if !transitionHandedToEngineLoad {
        finishBackendTransition(transitionToken)
      }
    }
    if let coreBackendService {
      do {
        let boot = try await coreBackendService.submitCoreRequest(
          .boot(loadLastState: true, firstLaunch: false, expectedBackendEpoch: 0)
        )
        coreBackendEpoch = boot.backendEpoch
        coreRevision = boot.revision
        coreCurrentRootID = boot.currentRoot
        coreBootSucceeded = true
        if let snapshot = boot.snapshot, snapshot.visibleTree.count > 1 || mainLine.isEmpty {
          applyCoreBackendResult(boot, reason: "coreBoot", allowWhileMutationsPending: true)
        } else if !mainLine.isEmpty {
          enqueueCurrentMainLineIntoCore(reason: "coreLaunchRecordRestore")
        }
      } catch {
        lastEngineError = localizedEngineError(error, fallbackKey: .engineErrorAnalysisFailed)
        hermesStatus = .offline
      }
      await waitForCoreMutationDrain()
      if coreBootSucceeded {
        do {
          try await submitCoreMutationAndWait(
            .setKomi(komi, expectedBackendEpoch: 0),
            reason: "coreLaunchKomiRestore"
          )
          try await submitCoreMutationAndWait(
            .setWideRootNoise(rootNoise, expectedBackendEpoch: 0),
            reason: "coreLaunchRootNoiseReset"
          )
        } catch {
          lastEngineError = localizedEngineError(error, fallbackKey: .engineErrorAnalysisFailed)
          hermesStatus = .offline
        }
      }
    }
    let restoredEngineTombstone = coreBackendService == nil
      ? await restoreEngineTombstoneIfAvailable()
      : false
    exportAutomationRealDeviceEvidenceIfRequested(
      environment: ProcessInfo.processInfo.environment,
      trigger: .launch
    )
    if selectedEngine != .none {
      transitionHandedToEngineLoad = true
      if restoredEngineTombstone {
        startAnalysis(
          engine: selectedEngine,
          assumesEngineAlreadyLoaded: true,
          transitionToken: transitionToken
        )
      } else {
        startAnalysis(
          engine: selectedEngine,
          assumesEngineAlreadyLoaded: false,
          transitionToken: transitionToken
        )
      }
    }
  }

  private func enqueueCurrentMainLineIntoCore(reason: String) {
    variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
    submitCoreMutation(
      .newGame(
        komi: komi,
        nextPla: mainLine.first?.color ?? .black,
        expectedBackendEpoch: 0
      ),
      reason: "\(reason)Reset"
    )
    var parent: QixiCoreRootReference = .node(0)
    for (index, move) in mainLine.enumerated() {
      guard index + 1 < variation.currentPathNodeIDs.count else { break }
      let intentID = nextCoreIntentID()
      let nodeID = variation.currentPathNodeIDs[index + 1]
      variation.coreRootReferenceByNodeID[nodeID] = .intent(intentID)
      let coreMove = move.isPass
        ? 361
        : coreMoveIndex(x: move.x ?? -1, y: move.y ?? -1)
      submitCoreMutation(
        .playMove(
          move: coreMove,
          uiIntentId: intentID,
          parentRoot: parent,
          expectedBackendEpoch: 0
        ),
        reason: "\(reason)Move",
        optimisticVariationNodeID: nodeID,
        uiIntentID: intentID
      )
      parent = .intent(intentID)
    }
  }

  private func resumeAnalysisForImportedSnapshotIfNeeded() {
    guard selectedEngine != .none else { return }
    startAnalysis(engine: selectedEngine, assumesEngineAlreadyLoaded: false)
  }

  func engineTombstoneFilenameIfSupported() -> String? {
    if coreBackendService != nil { return nil }
    return (analysisService as? any QixiEngineTombstoneService) == nil
      ? nil
      : QixiEngineTombstoneStore.tombstoneFilename
  }

  func exportEngineTombstoneIfSupported(reason: String) {
    guard let engineTombstoneService = analysisService as? any QixiEngineTombstoneService else { return }
    let tombstoneURL = QixiEngineTombstoneStore.tombstoneURL
    let engine = selectedEngine
    engineTombstoneTask?.cancel()
    let backgroundTask = QixiEngineTombstoneBackgroundTask(name: "QixiEngineTombstoneExport") { [weak self] in
      self?.engineTombstoneTask?.cancel()
    }
    engineTombstoneTask = Task { [weak self] in
      defer {
        Task { @MainActor in
          backgroundTask.end()
        }
      }
      do {
        try await engineTombstoneService.exportEngineTombstone(to: tombstoneURL)
        try QixiEngineTombstoneStore.markExported(engine: engine, reason: reason)
      } catch {
        await MainActor.run {
          self?.lastSaveError = "engine tombstone export \(reason): \(error)"
        }
      }
    }
  }

  private func restoreEngineTombstoneIfAvailable() async -> Bool {
    guard let engineTombstoneService = analysisService as? any QixiEngineTombstoneService else { return false }
    let tombstoneURL = QixiEngineTombstoneStore.tombstoneURL
    guard FileManager.default.fileExists(atPath: tombstoneURL.path) else { return false }
    let engine = selectedEngine
    do {
      try await engineTombstoneService.restoreEngineTombstone(from: tombstoneURL, for: engine)
      try QixiEngineTombstoneStore.markRestored(engine: engine)
      return true
    } catch {
      lastSaveError = "engine tombstone restore: \(error)"
      return false
    }
  }

  private func applyAutomationAnalysisFixtureIfNeeded(environment: [String: String]) {
    if environment["QIXI_SHOW_TERRITORY"] == "1" {
      showTerritory = true
    }
    switch environment["QIXI_ANALYSIS_FIXTURE"] {
    case "board-overlays":
      clearRecognizedSetup()
      currentWinrate = 0.642
      currentScoreMean = 2.8
      candidates = Self.boardOverlayFixtureCandidates
      territory = Self.boardOverlayFixtureTerritory
    case "board-capture-replay":
      clearRecognizedSetup()
      mainLine = Self.captureReplayFixtureLine
      currentPly = Self.captureReplayFixtureLine.count
      currentWinrate = 0.5
      currentScoreMean = 0.0
      candidates = []
      territory = []
      showTerritory = false
    case "board-recognition-preview":
      currentWinrate = 0.5
      currentScoreMean = 0.0
      candidates = []
      territory = []
      showTerritory = false
      lastBoardRecognition = Self.boardRecognitionPreviewFixture
    case "real-device-evidence":
      clearRecognizedSetup()
      selectedEngine = .b6
      currentWinrate = 0.642
      currentScoreMean = 2.8
      candidates = Self.boardOverlayFixtureCandidates
      territory = Self.boardOverlayFixtureTerritory
      let cacheKey = positionCacheKey(
        engine: .b6,
        moves: boardMoves,
        setupStones: analysisSetupStones,
        komi: komi,
        rootNoise: rootNoise
      )
      cacheCurrentAnalysis(engine: .b6, cacheKey: cacheKey, positionKey: cacheKey, visits: 4096)
      hermesStatus = .ready
      exportAutomationRealDeviceEvidenceIfRequested(environment: environment, trigger: .analysis)
    default:
      return
    }
  }

  @discardableResult
  private func applyAutomationInitialEngineIfNeeded(environment: [String: String]) -> Bool {
    guard environment["QIXI_ANALYSIS_FIXTURE"] == nil else { return false }
    guard let rawEngine = environment["QIXI_AUTOMATION_SELECT_ENGINE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawEngine.isEmpty else { return false }
    guard let engine = AnalysisEngine(rawValue: rawEngine), engine != .none else {
      selectedEngine = .none
      clearVisibleAnalysisAndRefreshAnchor()
      lastEngineError = "QIXI_AUTOMATION_SELECT_ENGINE must be b6, b18nbt, or b28nbt."
      hermesStatus = .offline
      return true
    }
    selectedEngine = engine
    return true
  }

  private func applyAutomationEngineErrorIfNeeded(environment: [String: String]) {
    guard let rawValue = environment["QIXI_ENGINE_ERROR"] else { return }
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    switch normalized {
    case "library-not-linked", "not-linked":
      lastEngineError = L10n.text(.engineErrorLibraryNotLinked)
    case "model-missing", "missing-model":
      lastEngineError = String(format: L10n.text(.engineErrorModelMissing), "b18nbt.bin")
    case "insufficient-memory", "low-memory":
      lastEngineError = String(
        format: L10n.text(.engineErrorInsufficientMemory),
        AnalysisEngine.b28nbt.title,
        2048,
        1024
      )
    case "local-network-denied", "local-network", "network-denied":
      lastEngineError = L10n.text(.engineErrorLocalNetworkDenied)
    default:
      return
    }
    hermesStatus = .offline
  }

  private func localizedEngineError(_ error: Error, fallbackKey: L10n.Key) -> String {
    if let nativeError = error as? QixiNativeKataGoServiceError {
      switch nativeError {
      case .libraryNotLinked:
        return L10n.text(.engineErrorLibraryNotLinked)
      case .modelMissing(let resourceName):
        return String(format: L10n.text(.engineErrorModelMissing), resourceName)
      case .insufficientDeviceMemory(let report):
        return String(
          format: L10n.text(.engineErrorInsufficientMemory),
          report.engine.title,
          report.minimumMemoryMB,
          report.availableMemoryMB
        )
      case .invalidRequest(let message):
        return String(format: L10n.text(fallbackKey), message)
      case .invalidBridgeResponse(let message):
        return String(format: L10n.text(fallbackKey), message)
      }
    }
    if Self.isLocalNetworkDenied(error) {
      return L10n.text(.engineErrorLocalNetworkDenied)
    }
    let message = (error as NSError).localizedDescription
    return String(format: L10n.text(fallbackKey), message)
  }

  private static func isLocalNetworkDenied(_ error: Error) -> Bool {
    let nsError = error as NSError
    let detail = String(describing: error)
    if detail.contains("Denied over Wi-Fi") || detail.contains("_NSURLErrorNWPathKey=unsatisfied") {
      return true
    }
    return nsError.domain == NSURLErrorDomain &&
      nsError.code == NSURLErrorNotConnectedToInternet &&
      detail.localizedCaseInsensitiveContains("local")
  }

  private func applyAutomationSyncStatusIfNeeded(environment: [String: String]) {
    guard let rawValue = environment["QIXI_SYNC_STATUS"] else { return }
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    switch normalized {
    case "synced", "success", "ok":
      syncStatus = QixiSyncStatus(
        provider: iCloudSyncEnabled ? .iCloud : .localFallback,
        lastSyncAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastError: nil
      )
    case "error", "failed":
      syncStatus = QixiSyncStatus(
        provider: iCloudSyncEnabled ? .iCloud : .localFallback,
        lastSyncAt: nil,
        lastError: L10n.text(.syncErrorMessage)
      )
    case "conflict", "conflicting":
      syncStatus = QixiSyncStatus(
        provider: iCloudSyncEnabled ? .iCloud : .localFallback,
        lastSyncAt: nil,
        lastError: L10n.text(.syncConflictMessage)
      )
    default:
      return
    }
  }

  var isAutomationSyncStatusPinned: Bool {
    QixiPreferences.iCloudSyncEnabledAutomationOverride != nil ||
      ProcessInfo.processInfo.environment["QIXI_SYNC_STATUS"] != nil
  }

  private func localSnapshotForManualSync() throws -> QixiAppSnapshot? {
    try persistence.localSnapshotForManualSync(isUntouchedDefault: isUntouchedLaunchDefaultState)
  }

  var isUntouchedLaunchDefaultState: Bool {
    selectedEngine == .none &&
      recognizedSetupStones == nil &&
      mainLine == Self.sampleLine &&
      currentPly == min(8, Self.sampleLine.count) &&
      komi == Self.defaultKomi &&
      showTerritory == false &&
      candidates.isEmpty &&
      territory.isEmpty &&
      analysisCache.isEmpty
  }

  func buildAppSnapshot(reason: String) -> QixiAppSnapshot {
    currentSnapshot(reason: reason)
  }

  private func currentSnapshot(reason: String) -> QixiAppSnapshot {
    QixiAppSnapshot(
      savedAt: Date(),
      saveReason: reason,
      selectedEngine: selectedEngine,
      currentPly: currentPly,
      mainLine: mainLine,
      recognizedSetupStones: recognizedSetupStones,
      komi: komi,
      showTerritory: showTerritory,
      analysisByEngine: analysisCache.snapshotMap
    )
  }

  private func recordRuntimeDiagnostic(event: String, success: Bool, message: String) {
    let diagnostic = QixiRuntimeDiagnostic(
      recordedAt: Date(),
      event: event,
      success: success,
      selectedEngine: selectedEngine,
      analysisRuntime: analysisService.runtime.rawValue,
      backendBaseURL: diagnosticBackendBaseURL(),
      message: String(message.prefix(2048))
    )
    do {
      try QixiRuntimeDiagnosticStore.record(diagnostic)
    } catch {
      lastSaveError = "runtime diagnostic: \(error)"
    }
  }

  private func diagnosticBackendBaseURL() -> String {
    // HTTP product path removed; diagnostics no longer record a Mac backend URL.
    ""
  }

  func setICloudSyncEnabled(_ enabled: Bool) {
    iCloudSyncEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: QixiPreferences.iCloudSyncEnabledKey)
  }

  private func scheduleAnalysisRefresh(reason: String) {
    if coreBackendService != nil {
      analysisRefreshTask?.cancel()
      switch reason {
      case "komiChanged":
        submitCoreMutation(.setKomi(komi, expectedBackendEpoch: 0), reason: "coreKomiChanged")
      case "rootNoiseChanged":
        submitCoreMutation(.setWideRootNoise(rootNoise, expectedBackendEpoch: 0), reason: "coreRootNoiseChanged")
      default:
        submitCoreMutation(.autosaveTick(reason: reason, expectedBackendEpoch: 0), reason: "coreRefresh")
      }
      return
    }
    guard selectedEngine != .none else { return }
    let engine = selectedEngine
    analysisRefreshTask?.cancel()
    analysisRefreshTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: QixiPersistenceCoordinator.saveDebounceNanoseconds)
      guard !Task.isCancelled else { return }
      self?.refreshAnalysisIfEngineUnchanged(engine)
    }
  }

  private func refreshAnalysisIfEngineUnchanged(_ engine: AnalysisEngine) {
    guard selectedEngine == engine else { return }
    startAnalysis(engine: engine, assumesEngineAlreadyLoaded: true)
  }

  private func refreshVisibleAnalysisForCurrentSettings() {
    if selectedEngine == .none {
      clearVisibleAnalysisAndRefreshAnchor()
    } else if !restoreCachedAnalysisForCurrentPosition() {
      clearVisibleAnalysisAndRefreshAnchor()
    }
  }

  private func restoreCachedAnalysisForCurrentPosition() -> Bool {
    guard selectedEngine != .none else { return false }
    let key = positionCacheKey(
      engine: selectedEngine,
      moves: boardMoves,
      setupStones: analysisSetupStones,
      komi: komi,
      rootNoise: rootNoise
    )
    return restoreCachedAnalysis(engine: selectedEngine, cacheKey: key)
  }

  private func currentAnalysisCacheKey(for engine: AnalysisEngine) -> String? {
    guard engine == selectedEngine, engine != .none else { return nil }
    return positionCacheKey(
      engine: engine,
      moves: boardMoves,
      setupStones: analysisSetupStones,
      komi: komi,
      rootNoise: rootNoise
    )
  }

  private func invalidateActiveAnalysisForPositionChange() {
    if coreBackendService != nil {
      analysisRefreshTask?.cancel()
      return
    }
    analysisTask?.cancel()
    analysisRefreshTask?.cancel()
    analysisGeneration += 1
  }

  @discardableResult
  private func restoreCachedAnalysis(engine: AnalysisEngine, cacheKey: String) -> Bool {
    guard let cached = analysisCache.entry(engine: engine, cacheKey: cacheKey) else { return false }
    currentWinrate = cached.winrate
    currentScoreMean = cached.scoreMean
    candidates = cached.candidates
    territory = cached.territory
    return true
  }

  private func cacheCurrentAnalysis(engine: AnalysisEngine, cacheKey: String, positionKey: String, visits: Int) {
    analysisCache.put(
      engine: engine,
      cacheKey: cacheKey,
      positionKey: positionKey,
      winrate: currentWinrate,
      scoreMean: currentScoreMean,
      visits: visits,
      candidates: candidates,
      territory: territory
    )
  }

  // MARK: - Product OOM unload (QixiMemoryPressureHost)

  func applySoftMemoryPressureRelief() async {
    memorySampler?.record(reason: "memoryPressure:soft")
    trimAnalysisCacheForMemoryPressure()
    guard selectedEngine != .none else { return }
    let token = beginBackendTransition(.memoryUnload)
    defer { finishBackendTransition(token) }
    updateBackendTransitionProgress(
      token,
      phase: L10n.text(.memoryPressureUnloadingEngine),
      fraction: 0.4
    )
    do {
      try await submitCoreEngineSelectionAndWait(.none, reason: "coreMemoryPressureSoftUnload")
      selectedEngine = .none
      hermesStatus = .offline
      analysisTask?.cancel()
      analysisRefreshTask?.cancel()
      updateBackendTransitionProgress(
        token,
        phase: L10n.text(.memoryPressureUnloadingEngine),
        fraction: 1.0
      )
    } catch {
      lastEngineError = error.localizedDescription
      recordRuntimeDiagnostic(
        event: "memoryPressureSoftUnloadFailed",
        success: false,
        message: error.localizedDescription
      )
    }
  }

  func applyHardMemoryPressureRelief() async {
    memorySampler?.record(reason: "memoryPressure:hard")
    // Ensure NN is not resident before serializing a large store under pressure.
    if selectedEngine != .none {
      await applySoftMemoryPressureRelief()
    }
    guard coreBackendService != nil else { return }
    let token = beginBackendTransition(.memoryUnload)
    startIoProgressPolling(for: token)
    defer { finishBackendTransition(token) }
    updateBackendTransitionProgress(
      token,
      phase: L10n.text(.memoryPressureSavingAndFreeing),
      fraction: 0.1
    )
    do {
      await waitForCoreMutationDrain()
      try await submitCoreMutationAndWait(
        .relieveMemoryPressure(level: 1, expectedBackendEpoch: 0),
        reason: "coreMemoryPressureHardUnload"
      )
      updateBackendTransitionProgress(
        token,
        phase: L10n.text(.memoryPressureSavingAndFreeing),
        fraction: 1.0,
        detail: L10n.text(.memoryPressureStoreUnloaded)
      )
      memorySampler?.record(reason: "memoryPressure:hardDone")
    } catch {
      lastEngineError = error.localizedDescription
      recordRuntimeDiagnostic(
        event: "memoryPressureHardUnloadFailed",
        success: false,
        message: error.localizedDescription
      )
    }
  }

  private func trimAnalysisCacheForMemoryPressure() {
    analysisCache.trimToCurrent(
      engine: selectedEngine,
      cacheKey: currentAnalysisCacheKey(for: selectedEngine)
    )
  }

  private func memoryTelemetryContext() -> QixiMemoryTelemetryContext {
    let cachedRootVisits = currentCachedAnalysisForEvidence()?.visits
    let visibleRootVisits = candidates.reduce(0) { total, candidate in
      total + max(0, candidate.visits)
    }
    let topCandidateVisits = candidates.map(\.visits).max() ?? 0
    return QixiMemoryTelemetryContext(
      selectedEngine: selectedEngine.rawValue,
      hermesStatus: hermesStatus.telemetryValue,
      currentPly: currentPly,
      mainLineCount: mainLine.count,
      rootVisits: max(0, cachedRootVisits ?? visibleRootVisits),
      candidateCount: candidates.count,
      topCandidateVisits: max(0, topCandidateVisits),
      showTerritory: showTerritory
    )
  }

  private func currentCachedAnalysisForEvidence() -> QixiCachedAnalysis? {
    guard selectedEngine != .none else { return nil }
    let cacheKey = positionCacheKey(
      engine: selectedEngine,
      moves: boardMoves,
      setupStones: analysisSetupStones,
      komi: komi,
      rootNoise: rootNoise
    )
    return analysisCache.entry(engine: selectedEngine, cacheKey: cacheKey)
  }

  private func nativeEngineEvidenceForCurrentSelection(recordedAt: Date) throws -> QixiRealDeviceEvidence.NativeEngine? {
    guard analysisService.runtime == .nativeInProcess else { return nil }
    guard let spec = QixiNativeModelRegistry.spec(for: selectedEngine) else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process real-device evidence requires a supported selected engine."
      )
    }
    guard let resolvedModel = QixiNativeModelStore().resolvedModel(for: spec) else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process real-device evidence requires an installed or bundled model matching the manifest."
      )
    }
    let modelReport = try QixiNativeModelIntegrity.verifyModel(at: resolvedModel.fileURL, spec: spec)
    var coreMLPackageReports: [QixiRealDeviceEvidence.NativeEngine.CoreMLPackage] = []
    for (offset, packageSpec) in spec.coreMLPackages.enumerated() {
      guard offset < resolvedModel.coreMLPackageURLs.count else {
        throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
          "Native in-process real-device evidence requires every CoreML companion package."
        )
      }
      let report = try QixiNativeCoreMLPackageIntegrity.verifyPackage(
        at: resolvedModel.coreMLPackageURLs[offset],
        packageSpec: packageSpec
      )
      coreMLPackageReports.append(QixiRealDeviceEvidence.NativeEngine.CoreMLPackage(
        resourceName: report.resourceName,
        variantID: packageSpec.variantID,
        fileCount: report.fileCount,
        totalByteCount: report.totalByteCount,
        sha256TreeDigest: report.sha256TreeDigest
      ))
    }
    guard let exportAudit = QixiEngineTombstoneStore.loadExportAudit(),
          exportAudit.engine == selectedEngine,
          exportAudit.tombstoneFilename == QixiEngineTombstoneStore.tombstoneFilename else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process real-device evidence requires a matching tombstone export audit."
      )
    }
    guard let restoreAudit = QixiEngineTombstoneStore.loadRestoreAudit(),
          restoreAudit.engine == selectedEngine,
          restoreAudit.tombstoneFilename == QixiEngineTombstoneStore.tombstoneFilename else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process real-device evidence requires a matching tombstone restore audit."
      )
    }
    guard exportAudit.exportedAt <= recordedAt,
          recordedAt.timeIntervalSince(exportAudit.exportedAt) <= QixiRealDeviceEvidenceStore.maximumNativeTombstoneAuditAge,
          restoreAudit.restoredAt <= recordedAt,
          recordedAt.timeIntervalSince(restoreAudit.restoredAt) <= QixiRealDeviceEvidenceStore.maximumNativeTombstoneAuditAge else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process real-device evidence requires fresh tombstone export and restore audits."
      )
    }
    return QixiRealDeviceEvidence.NativeEngine(
      modelDigestVerified: true,
      engineId: selectedEngine,
      modelResourceName: modelReport.resourceName,
      modelByteCount: modelReport.byteCount,
      modelSHA256HexDigest: modelReport.sha256HexDigest,
      coreMLPackages: coreMLPackageReports,
      tombstoneExported: true,
      tombstoneFilename: exportAudit.tombstoneFilename,
      tombstoneExportedAt: exportAudit.exportedAt,
      tombstoneRestored: true,
      tombstoneRestoredAt: restoreAudit.restoredAt
    )
  }

  private func exportAutomationRealDeviceEvidenceIfRequested(
    environment: [String: String],
    trigger: QixiAutomationEvidenceExportTrigger
  ) {
    guard environment[trigger.environmentKey] == "1" else { return }
    guard !hasExportedAutomationRealDeviceEvidence else { return }
    do {
      try rejectBackendEnvironmentForNativeEvidence(environment: environment)
      let outputURL = try automationEvidenceOutputURL(environment: environment)
      let runId = try requiredStringEnvironment("QIXI_REAL_DEVICE_RUN_ID", environment: environment)
      let recordedAt = try automationEvidenceRecordedAt(environment: environment, trigger: trigger)
      let deviceLogArtifactPath = try requiredStringEnvironment(
        "QIXI_REAL_DEVICE_DEVICE_LOG_ARTIFACT",
        environment: environment
      )
      try exportCurrentRealDeviceEvidence(
        device: automationEvidenceDevice(environment: environment),
        backend: try automationEvidenceBackend(environment: environment),
        measurements: try automationEvidenceMeasurements(environment: environment),
        lifecycle: try automationEvidenceLifecycle(environment: environment),
        features: try automationEvidenceFeatures(environment: environment),
        artifacts: try automationEvidenceInputArtifacts(environment: environment, evidenceURL: outputURL),
        autoWriteDeviceLogArtifactPath: deviceLogArtifactPath,
        to: outputURL,
        runId: runId,
        recordedAt: recordedAt
      )
      hasExportedAutomationRealDeviceEvidence = true
    } catch {
      let outputURL = automationEvidenceFailureAuditEvidenceURL(for: error, environment: environment)
      QixiRealDeviceEvidenceStore.markExportFailed(error: error, evidenceURL: outputURL)
      lastSaveError = "real device evidence export: \(error)"
    }
  }

  private func automationEvidenceFailureAuditEvidenceURL(for error: Error, environment: [String: String]) -> URL {
    if let automationError = error as? QixiAutomationEvidenceError,
       case .forbiddenBackendEnvironment = automationError {
      return QixiRealDeviceEvidenceStore.evidenceURL
    }
    return (try? automationEvidenceOutputURL(environment: environment)) ??
      QixiRealDeviceEvidenceStore.evidenceURL
  }

  private func automationEvidenceRecordedAt(
    environment: [String: String],
    trigger: QixiAutomationEvidenceExportTrigger
  ) throws -> Date {
    let configuredDate = try requiredDateEnvironment("QIXI_REAL_DEVICE_RECORDED_AT", environment: environment)
    guard trigger == .launch else { return configuredDate }
    return max(configuredDate, Date())
  }

  private func automationEvidenceOutputURL(environment: [String: String]) throws -> URL {
    guard let rawPath = environment["QIXI_REAL_DEVICE_EVIDENCE_OUTPUT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawPath.isEmpty else {
      return QixiRealDeviceEvidenceStore.evidenceURL
    }
    let outputURL: URL
    if rawPath.hasPrefix("/") {
      outputURL = URL(fileURLWithPath: rawPath)
    } else {
      if rawPath.hasPrefix("~") || rawPath.contains("\\") {
        throw QixiAutomationEvidenceError.invalidOutputPath("QIXI_REAL_DEVICE_EVIDENCE_OUTPUT")
      }
      let components = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw QixiAutomationEvidenceError.invalidOutputPath("QIXI_REAL_DEVICE_EVIDENCE_OUTPUT")
      }
      outputURL = components.reduce(QixiSnapshotStore.snapshotsDirectory) { partialURL, component in
        partialURL.appendingPathComponent(component, isDirectory: false)
      }
    }
    try QixiRealDeviceEvidenceStore.validateEvidenceOutputURL(outputURL)
    return outputURL
  }

  private func automationEvidenceDevice(environment: [String: String]) -> QixiRealDeviceEvidence.Device {
    #if targetEnvironment(simulator)
    let defaultSimulatorFlag = true
    #else
    let defaultSimulatorFlag = false
    #endif
    return QixiRealDeviceEvidence.Device(
      idiom: environment["QIXI_REAL_DEVICE_IDIOM"] ?? currentDeviceIdiom,
      model: environment["QIXI_REAL_DEVICE_MODEL"] ?? UIDevice.current.model,
      osVersion: environment["QIXI_REAL_DEVICE_OS_VERSION"] ?? "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
      simulator: boolEnvironmentValue(environment["QIXI_REAL_DEVICE_SIMULATOR"]) ?? defaultSimulatorFlag
    )
  }

  private var currentDeviceIdiom: String {
    switch UIDevice.current.userInterfaceIdiom {
    case .pad: return "iPad"
    case .phone: return "iPhone"
    default: return UIDevice.current.model.hasPrefix("iPad") ? "iPad" : "iPhone"
    }
  }

  private func automationEvidenceBackend(environment: [String: String]) throws -> QixiRealDeviceEvidence.Backend? {
    #if QIXI_NATIVE_RELEASE
    return nil
    #else
    guard analysisService.runtime == .httpBridge else { return nil }
    let backendURL = try requiredStringEnvironment(
      environment["QIXI_DEVICE_BACKEND_URL"] == nil ? "QIXI_BACKEND_URL" : "QIXI_DEVICE_BACKEND_URL",
      environment: environment
    )
    return QixiRealDeviceEvidence.Backend(
      url: backendURL,
      status: QixiRealDeviceEvidence.BackendStatus(
        engine: selectedEngine == .none ? "none" : "katago-metal-mux:\(selectedEngine.rawValue)",
        engineId: selectedEngine.rawValue,
        state: hermesStatus == .ready ? "running" : "ready",
        running: selectedEngine != .none,
        paused: false
      )
    )
    #endif
  }

  private func validateRealDeviceEvidenceBackendInput(_ backend: QixiRealDeviceEvidence.Backend?) throws {
    guard analysisService.runtime == .nativeInProcess else { return }
    guard backend == nil else {
      throw QixiRealDeviceEvidenceValidationError.invalidAnalysis(
        "Native in-process real-device evidence must omit backend transport entirely."
      )
    }
  }

  private func rejectBackendEnvironmentForNativeEvidence(environment: [String: String]) throws {
    #if QIXI_NATIVE_RELEASE
    return
    #else
    guard analysisService.runtime == .nativeInProcess else { return }
    let forbiddenBackendKeys = ["QIXI_DEVICE_BACKEND_URL", "QIXI_BACKEND_URL"].filter { key in
      guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
      return !value.isEmpty
    }
    guard forbiddenBackendKeys.isEmpty else {
      throw QixiAutomationEvidenceError.forbiddenBackendEnvironment(forbiddenBackendKeys.joined(separator: ", "))
    }
    #endif
  }

  private func automationEvidenceMeasurements(environment: [String: String]) throws -> QixiRealDeviceEvidence.Measurements {
    QixiRealDeviceEvidence.Measurements(
      launch: QixiRealDeviceEvidence.Launch(
        coldLaunchMs: try requiredIntEnvironment("QIXI_REAL_DEVICE_COLD_LAUNCH_MS", environment: environment),
        visualReadyMs: try requiredIntEnvironment("QIXI_REAL_DEVICE_VISUAL_READY_MS", environment: environment)
      ),
      memory: QixiRealDeviceEvidence.Memory(
        peakRSSMB: try requiredDoubleEnvironment("QIXI_REAL_DEVICE_PEAK_RSS_MB", environment: environment),
        postAnalysisRSSMB: try requiredDoubleEnvironment("QIXI_REAL_DEVICE_POST_ANALYSIS_RSS_MB", environment: environment)
      ),
      framePacing: QixiRealDeviceEvidence.FramePacing(
        targetRefreshHz: try requiredIntEnvironment("QIXI_REAL_DEVICE_TARGET_REFRESH_HZ", environment: environment),
        observedRefreshHz: try requiredDoubleEnvironment("QIXI_REAL_DEVICE_OBSERVED_REFRESH_HZ", environment: environment),
        droppedFramePercent: try requiredDoubleEnvironment("QIXI_REAL_DEVICE_DROPPED_FRAME_PERCENT", environment: environment)
      )
    )
  }

  private func automationEvidenceLifecycle(environment: [String: String]) throws -> QixiRealDeviceEvidence.Lifecycle {
    QixiRealDeviceEvidence.Lifecycle(
      backgroundedSeconds: try requiredIntEnvironment("QIXI_REAL_DEVICE_BACKGROUNDED_SECONDS", environment: environment),
      autosaveWritten: boolEnvironmentValue(environment["QIXI_REAL_DEVICE_AUTOSAVE_WRITTEN"]) ?? false,
      tombstoneWritten: boolEnvironmentValue(environment["QIXI_REAL_DEVICE_TOMBSTONE_WRITTEN"]) ?? false,
      restoredLatestState: boolEnvironmentValue(environment["QIXI_REAL_DEVICE_RESTORED_LATEST_STATE"]) ?? false
    )
  }

  private func automationEvidenceFeatures(environment: [String: String]) throws -> QixiRealDeviceEvidence.Features {
    QixiRealDeviceEvidence.Features(
      cameraRecognitionTested: boolEnvironmentValue(environment["QIXI_REAL_DEVICE_CAMERA_RECOGNITION_TESTED"]) ?? false,
      iCloudSyncTested: boolEnvironmentValue(environment["QIXI_REAL_DEVICE_ICLOUD_SYNC_TESTED"]) ?? false,
      modelImportTested: boolEnvironmentValue(environment["QIXI_REAL_DEVICE_MODEL_IMPORT_TESTED"]) ?? false
    )
  }

  private func automationEvidenceInputArtifacts(
    environment: [String: String],
    evidenceURL: URL
  ) throws -> [QixiRealDeviceEvidence.Artifact] {
    [
      try QixiRealDeviceEvidenceStore.fingerprintedArtifact(
        kind: "screenshot",
        path: try requiredStringEnvironment("QIXI_REAL_DEVICE_SCREENSHOT_ARTIFACT", environment: environment),
        evidenceURL: evidenceURL
      ),
      try QixiRealDeviceEvidenceStore.fingerprintedArtifact(
        kind: "performance",
        path: try requiredStringEnvironment("QIXI_REAL_DEVICE_PERFORMANCE_ARTIFACT", environment: environment),
        evidenceURL: evidenceURL
      )
    ]
  }

  private func requiredStringEnvironment(_ key: String, environment: [String: String]) throws -> String {
    guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      throw QixiAutomationEvidenceError.missingEnvironment(key)
    }
    return value
  }

  private func requiredIntEnvironment(_ key: String, environment: [String: String]) throws -> Int {
    let value = try requiredStringEnvironment(key, environment: environment)
    guard let integer = Int(value) else {
      throw QixiAutomationEvidenceError.invalidInteger(key)
    }
    return integer
  }

  private func requiredDoubleEnvironment(_ key: String, environment: [String: String]) throws -> Double {
    let value = try requiredStringEnvironment(key, environment: environment)
    guard let number = Double(value), number.isFinite else {
      throw QixiAutomationEvidenceError.invalidDouble(key)
    }
    return number
  }

  private func requiredDateEnvironment(_ key: String, environment: [String: String]) throws -> Date {
    let value = try requiredStringEnvironment(key, environment: environment)
    guard let date = QixiRealDeviceEvidenceStore.parseISO8601Date(value) else {
      throw QixiAutomationEvidenceError.invalidDate(key)
    }
    return date
  }

  private func boolEnvironmentValue(_ value: String?) -> Bool? {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on": return true
    case "0", "false", "no", "n", "off": return false
    default: return nil
    }
  }

  private func apply(snapshot: QixiAppSnapshot) {
    isApplyingSnapshot = true
    persistence.cancelPendingSave()
    invalidateActiveAnalysisForPositionChange()
    defer { isApplyingSnapshot = false }
    let restoredSetupStones = Self.normalizedSetupStones(snapshot.recognizedSetupStones ?? [])
    let hasRestoredSetup = !restoredSetupStones.isEmpty
    recognizedSetupStones = hasRestoredSetup ? restoredSetupStones : nil
    let restoredMainLine = snapshot.mainLine.isEmpty && !hasRestoredSetup ? Self.sampleLine : snapshot.mainLine
    mainLine = restoredMainLine
    komi = snapshot.komi
    rootNoise = Self.defaultRootNoise
    currentPly = min(max(0, snapshot.currentPly), restoredMainLine.count)
    resetVariationTree(from: restoredMainLine, currentPly: currentPly)
    selectedEngine = snapshot.selectedEngine
    showTerritory = snapshot.showTerritory
    analysisCache.replaceAll(snapshot.analysisByEngine)
    clearBoardRecognitionPreview()
    if selectedEngine == .none {
      clearVisibleAnalysisAndRefreshAnchor()
    } else if !restoreCachedAnalysisForCurrentPosition() {
      clearVisibleAnalysisAndRefreshAnchor()
    }
  }

  private func positionCacheKey(
    engine: AnalysisEngine,
    moves: [BoardMove],
    setupStones: [BoardSetupStone] = [],
    komi: Double,
    rootNoise: Double
  ) -> String {
    QixiAnalysisCache.cacheKey(
      engine: engine,
      moves: moves,
      setupStones: setupStones,
      komi: komi,
      rootNoise: rootNoise
    )
  }

  private func clearBoardRecognitionPreview() {
    lastBoardRecognition = nil
  }

  private func clearRecognizedSetup() {
    let hadSetup = recognizedSetupStones != nil
    recognizedSetupStones = nil
    clearBoardRecognitionPreview()
    if hadSetup {
      updateBoardMoveCache()
    }
  }

  private static func normalizedRecognizedStones(_ stones: [RecognizedBoardStone]) -> [RecognizedBoardStone] {
    var bestByPoint: [Int: RecognizedBoardStone] = [:]
    for stone in stones where stone.x >= 0 && stone.x < 19 && stone.y >= 0 && stone.y < 19 {
      let id = stone.y * 19 + stone.x
      if let existing = bestByPoint[id], existing.confidence >= stone.confidence {
        continue
      }
      bestByPoint[id] = stone
    }
    return bestByPoint.values.sorted {
      if $0.y != $1.y { return $0.y < $1.y }
      if $0.x != $1.x { return $0.x < $1.x }
      return $0.color.rawValue < $1.color.rawValue
    }
  }

  private static func setupStones(from stones: [RecognizedBoardStone]) -> [BoardSetupStone] {
    normalizedSetupStones(stones.map { BoardSetupStone(color: $0.color, x: $0.x, y: $0.y) })
  }

  private static func normalizedSetupStones(_ stones: [BoardSetupStone]) -> [BoardSetupStone] {
    var bestByPoint: [Int: BoardSetupStone] = [:]
    for stone in stones where stone.x >= 0 && stone.x < 19 && stone.y >= 0 && stone.y < 19 {
      bestByPoint[stone.id] = stone
    }
    return bestByPoint.values.sorted {
      if $0.y != $1.y { return $0.y < $1.y }
      if $0.x != $1.x { return $0.x < $1.x }
      return $0.color.rawValue < $1.color.rawValue
    }
  }

  private static let sampleLine: [BoardMove] = [
    BoardMove(color: .black, x: 3, y: 15),
    BoardMove(color: .white, x: 15, y: 3),
    BoardMove(color: .black, x: 15, y: 15),
    BoardMove(color: .white, x: 3, y: 3),
    BoardMove(color: .black, x: 9, y: 15),
    BoardMove(color: .white, x: 9, y: 3),
    BoardMove(color: .black, x: 6, y: 12),
    BoardMove(color: .white, x: 12, y: 6),
    BoardMove(color: .black, x: 10, y: 14),
    BoardMove(color: .white, x: 8, y: 4),
    BoardMove(color: .black, x: 4, y: 10),
    BoardMove(color: .white, x: 14, y: 8)
  ]

  private static let captureReplayFixtureLine: [BoardMove] = [
    BoardMove(color: .white, x: 9, y: 9),
    BoardMove(color: .black, x: 8, y: 9),
    BoardMove(color: .black, x: 10, y: 9),
    BoardMove(color: .black, x: 9, y: 8),
    BoardMove(color: .black, x: 9, y: 10)
  ]

  private static let boardOverlayFixtureCandidates: [CandidateMove] = [
    CandidateMove(x: 10, y: 10, rank: 1, winrate: 0.642, visits: 2048, scoreMean: 2.8),
    CandidateMove(x: 16, y: 10, rank: 2, winrate: 0.626, visits: 1024, scoreMean: 1.6),
    CandidateMove(x: 4, y: 7, rank: 3, winrate: 0.596, visits: 768, scoreMean: 0.7),
    CandidateMove(x: 13, y: 13, rank: 4, winrate: 0.594, visits: 512, scoreMean: -0.4)
  ]

  private static let boardOverlayFixtureTerritory: [TerritoryPoint] = [
    TerritoryPoint(x: 2, y: 5, ownership: 0.92),
    TerritoryPoint(x: 5, y: 5, ownership: 0.74),
    TerritoryPoint(x: 16, y: 16, ownership: 0.88),
    TerritoryPoint(x: 16, y: 5, ownership: -0.91),
    TerritoryPoint(x: 5, y: 16, ownership: -0.82),
    TerritoryPoint(x: 10, y: 2, ownership: -0.76)
  ]

  private static let boardRecognitionPreviewFixture = QixiBoardRecognitionResult(
    stones: [
      RecognizedBoardStone(x: 3, y: 3, color: .black, confidence: 0.94),
      RecognizedBoardStone(x: 15, y: 3, color: .white, confidence: 0.91),
      RecognizedBoardStone(x: 10, y: 10, color: .black, confidence: 0.88),
      RecognizedBoardStone(x: 16, y: 16, color: .white, confidence: 0.86)
    ],
    gridX: Array(0..<19).map(Double.init),
    gridY: Array(0..<19).map(Double.init)
  )
}
