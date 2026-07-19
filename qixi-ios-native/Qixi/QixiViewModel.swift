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
  /// Visits for this move at the current root (0 if not among published candidates).
  var currentRootVisits: Int
  var childRootVisits: Int
  var childRootCache: QixiCachedAnalysis?

  var pointID: Int {
    y * 19 + x
  }

  /// Sampled when MCTS has visits on the move, or the child position has been analyzed.
  var isSampled: Bool {
    currentRootVisits > 0 || childRootVisits > 0
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
  /// Once any non-none engine has been chosen this session, the none control shows “Pause”.
  @Published private(set) var engineHasBeenEnabled = false
  /// Engine whose cached/painted analysis is kept while paused (`selectedEngine == .none`).
  private var pausedAnalysisEngine: AnalysisEngine?
  @Published var hermesStatus: HermesStatus = .ready {
    didSet { refreshSwitchMonitorSnapshot() }
  }
  /// On-device model-switch phase monitor (UI between tree and engine strip).
  let switchMonitor = QixiSwitchMonitor()
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
        return
      }
      guard !isApplyingSnapshot else { return }
      guard komi != oldValue else { return }
      memoizedCurrentAnalysisCacheKey = nil
      invalidateChartPointsCache()
      persistence.saveSoon(reason: "komiChanged")
      refreshVisibleAnalysisForCurrentSettings()
      // Immediate single core swap for the committed value (no "wait until steady").
      scheduleAnalysisRefresh(reason: "komiChanged")
    }
  }
  @Published var rootNoise: Double = QixiViewModel.defaultRootNoise {
    didSet {
      let normalized = QixiAnalysisLimits.normalizedRootNoise(rootNoise)
      if normalized != rootNoise {
        rootNoise = normalized
        return
      }
      guard !isApplyingSnapshot else { return }
      guard rootNoise != oldValue else { return }
      memoizedCurrentAnalysisCacheKey = nil
      invalidateChartPointsCache()
      persistence.saveSoon(reason: "rootNoiseChanged")
      refreshVisibleAnalysisForCurrentSettings()
      scheduleAnalysisRefresh(reason: "rootNoiseChanged")
    }
  }

  /// User finished editing the komi number field (Done / focus loss). One value only.
  func commitKomiSetting(_ raw: Double) {
    let rounded = Self.roundSetting(raw, fractionDigits: 1)
    let next = QixiAnalysisLimits.normalizedKomi(rounded)
    guard abs(next - komi) > 1e-12 else { return }
    komi = next
  }

  /// User finished editing the wide-root-noise number field (Done / focus loss). One value only.
  func commitRootNoiseSetting(_ raw: Double) {
    let rounded = Self.roundSetting(raw, fractionDigits: 2)
    let clamped = min(
      max(rounded, QixiAnalysisLimits.minRootNoise),
      QixiAnalysisLimits.uiMaxRootNoise
    )
    let next = QixiAnalysisLimits.normalizedRootNoise(clamped)
    guard abs(next - rootNoise) > 1e-12 else { return }
    rootNoise = next
  }

  private static func roundSetting(_ value: Double, fractionDigits: Int) -> Double {
    guard value.isFinite else { return value }
    let scale = pow(10.0, Double(max(0, fractionDigits)))
    return (value * scale).rounded() / scale
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
  /// Pending navigation blocked by unsaved changes (save / discard / cancel).
  @Published var pendingUnsavedDecision: QixiUnsavedChangesDecision?
  @Published private(set) var sessionHasUnsavedChanges = false
  @Published private(set) var lastBoardRecognition: QixiBoardRecognitionResult?
  private(set) var visibleBoardStones: [VisibleBoardStone] = []
  private(set) var visibleStoneColorsByID: [Int: StoneColor] = [:]
  private(set) var occupiedBoardPointIDs = Set<Int>()
  private(set) var nextMoveCapturedBoardPointIDs = Set<Int>()
  /// When true, stones captured by the known next move are drawn as faint outlines.
  @Published private(set) var nextMoveShowsCaptureOutlines = false

  let analysisService: any QixiAnalysisService
  private var analysisTask: Task<Void, Never>?
  private var analysisRefreshTask: Task<Void, Never>?
  private var analysisGeneration = 0
  private var analysisCache = QixiAnalysisCache()
  private let persistence = QixiPersistenceCoordinator()
  private let syncCoordinator = QixiSyncCoordinator()
  private var cachedBoardMoves: [BoardMove] = []
  private var bestCandidateWinrate: Double?
  private var cachedVisibleCandidates: [CandidateMove] = []
  private var cachedVisibleCandidateOverlays: [VisibleCandidateOverlay] = []
  private var recognizedSetupStones: [BoardSetupStone]?
  /// WPS-style current document: nil base name ⇒ untitled (first save asks for a name).
  /// When set, Save replaces that package (and companion `.sgf`) in place.
  private var currentArchiveBaseName: String?
  private var currentArchivePackageURL: URL?
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
  /// Plane A: analyze overlays only (candidates + ownership). Not board/chrome.
  let analyzeDisplay = QixiAnalyzeDisplayModel()
  /// Count of in-flight Plane B nav ops (play/switch). HUD/structure accepted only at 0.
  private var planeBNavInFlight: Int = 0
  /// Bumped when in-flight Plane B settlements must be abandoned (engine switch / hard reset).
  private var planeBSettlementGeneration: UInt64 = 0
  /// Last core root id whose analyze plane was applied to the UI.
  private var lastAppliedAnalyzeCoreRoot: UInt32?
  /// Throttle HUD→analysis-cache writes (position-key + array copies are not 120 Hz safe).
  private var lastHUDCacheVisits: Int = -1
  private var lastHUDCacheRoot: UInt32 = UInt32.max
  private var lastHUDCacheAt: ContinuousClock.Instant?
  /// Engine actually loaded in the native core (may lag UI selection during a switch).
  private(set) var loadedEngine: AnalysisEngine = .none {
    didSet { refreshSwitchMonitorSnapshot() }
  }
  /// Wall-clock for diagnosing multi-second "switch" perception (tap → unlock).
  private var engineSwitchWallStart: ContinuousClock.Instant?
  private var engineSwitchTarget: AnalysisEngine?
  /// Avoid rebuilding next-move child cache keys on every HUD tick.
  private var lastNextMoveDecorationKey: NextMoveDecorationKey?
  private var cachedVariationTree: VariationTree?
  private var cachedVariationTreeSerial: UInt64 = 0
  private var variationTreeSerial: UInt64 = 0
  /// Memoized semantic cache key for the visible root (invalidated on board change).
  private var memoizedCurrentAnalysisCacheKey: String?
  private var memoizedCurrentAnalysisCacheEngine: AnalysisEngine = .none
  /// Memoized chart series (avoid O(plies) rebuild on every analyzeDisplay tick).
  private var cachedChartPoints: [ChartPoint] = []
  private var cachedChartPointsSerial: UInt64 = 0
  private var chartPointsSerial: UInt64 = 0

  private struct NextMoveDecorationKey: Equatable {
    var ply: Int
    var pointID: Int
    var color: StoneColor
    var currentRootVisits: Int
    var childRootVisits: Int
    var hudSampledVisits: Int
    var isSampled: Bool
    var forcedVisits: Int
    var forcedWinrateBits: UInt64
  }

  var coreBackendService: (any QixiCoreBackendService)? {
    analysisService as? any QixiCoreBackendService
  }

  // Exposed for QixiCoreMutationHost
  var analysisServiceForHost: any QixiAnalysisService { analysisService }

  var isBackendInteractionBlocked: Bool {
    blockingSession.isBlocked
  }

  /// Board play / scrub / pass — must not wait on a finished model load's leftover barrier,
  /// and must not allow moves while the selected model is not the one loaded in core.
  private var isBoardPlayBlocked: Bool {
    if let job = activeBlockingJob {
      switch job.kind {
      case .exportingState, .importingState, .installingModel, .memoryUnload, .memoryReload:
        return true
      case .switchingEngine, .restoringState:
        // Block only until the selected model is actually live.
        return selectedEngine != .none && loadedEngine != selectedEngine
      }
    }
    if selectedEngine != .none && loadedEngine != selectedEngine {
      return true
    }
    return false
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

  /// Finish every stacked switching/restoring barrier so a new model pick cannot
  /// leave the app permanently blocked after rapid taps.
  private func clearSupersededEngineSwitchBarriers() {
    while let job = activeBlockingJob,
          job.kind == .switchingEngine || job.kind == .restoringState {
      finishBackendTransition(job.id)
    }
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
    self.analysisService = analysisService ?? QixiAnalysisServiceFactory.makeDefaultService()
    self.language = AppLanguage.current
    self.onboardingCompleted = QixiPreferences.shouldSkipOnboardingForAutomation ||
      UserDefaults.standard.bool(forKey: QixiPreferences.onboardingCompletedKey)
    // No user-facing iCloud configuration. Prefer the ubiquity container when it is
    // available; automation can still force on/off for screenshots and tests.
    let launchSyncOverride = QixiPreferences.iCloudSyncEnabledAutomationOverride
    let launchSyncEnabled = QixiSyncStore.launchSyncEnabled(
      requestedEnabled: QixiSyncStore.isICloudContainerAvailable,
      automationOverride: launchSyncOverride
    )
    self.iCloudSyncEnabled = launchSyncEnabled

    // Cold launch: empty board (no demo sample line). No app-snapshot / tombstone restore.
    // No autosave / auto-sync. MCTS disk checkpoint remains for OOM hard unload only.
    self.mainLine = []
    self.komi = Self.defaultKomi
    self.currentPly = 0
    self.selectedEngine = .none
    self.showTerritory = false
    self.recognizedSetupStones = nil
    self.explicitRootSideToMove = .black

    resetVariationTree(from: mainLine, currentPly: currentPly)
    updateBoardMoveCache()
    refreshLocalChartAnchor()
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
    persistence.attach(host: self)
    persistence.startAutosaveTimer()
    syncCoordinator.attach(host: self)
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

  /// Explicit root side-to-move (SGF PL / import). Falls back to first-move color, then Black.
  private var explicitRootSideToMove: StoneColor?

  /// Color to play at the empty-history root of the current line.
  private var rootSideToMove: StoneColor {
    explicitRootSideToMove ?? mainLine.first?.color ?? .black
  }

  var nextColor: StoneColor {
    // Must not use even/odd ply: White-first lines and setup roots break parity.
    QixiBoardPosition.nextPlayer(after: boardMoves, rootToMove: rootSideToMove)
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
    // Prefer live engine HUD metrics so the corner tracks the active engine immediately.
    // While paused, analyzeDisplay may still hold the last frame — use it if visits exist.
    if analyzeDisplay.rootVisits > 0, selectedEngine != .none || pausedAnalysisEngine != nil {
      let (winrate, scoreMean) = Self.blackSideChartValues(
        winrate: analyzeDisplay.rootWinrate,
        scoreMean: analyzeDisplay.rootScoreMean,
        atPly: currentPly,
        mainLine: mainLine
      )
      return ChartPoint(ply: currentPly, winrate: winrate, scoreMean: scoreMean)
    }
    guard let cached = cachedChartAnalysis(at: currentPly) else { return nil }
    let (winrate, scoreMean) = Self.blackSideChartValues(
      winrate: cached.winrate,
      scoreMean: cached.scoreMean,
      atPly: currentPly,
      mainLine: mainLine
    )
    return ChartPoint(ply: currentPly, winrate: winrate, scoreMean: scoreMean)
  }

  var chartPoints: [ChartPoint] {
    // Active engine or paused-with-prior-analysis: show historical cache series.
    guard analysisEngineForCachedDisplay != nil else { return [] }
    let historical: [ChartPoint]
    if cachedChartPointsSerial == chartPointsSerial {
      historical = cachedChartPoints
    } else {
      let lastPly = mainLine.count
      var points: [ChartPoint] = []
      points.reserveCapacity(lastPly + 1)
      for ply in 0...lastPly {
        if let cached = cachedChartAnalysis(at: ply) {
          let (winrate, scoreMean) = Self.blackSideChartValues(
            winrate: cached.winrate,
            scoreMean: cached.scoreMean,
            atPly: ply,
            mainLine: mainLine
          )
          points.append(ChartPoint(ply: ply, winrate: winrate, scoreMean: scoreMean))
        }
      }
      cachedChartPoints = points
      cachedChartPointsSerial = chartPointsSerial
      historical = points
    }
    // Splice live HUD metrics for the visible ply so the polyline tracks between
    // throttled cache writes (analyzeDisplay updates at full HUD rate).
    guard selectedEngine != .none, let live = currentChartPoint else { return historical }
    var points = historical
    if let idx = points.firstIndex(where: { $0.ply == live.ply }) {
      points[idx] = live
    } else if let insertAt = points.firstIndex(where: { $0.ply > live.ply }) {
      points.insert(live, at: insertAt)
    } else {
      points.append(live)
    }
    return points
  }

  /// Title for the engine strip control (none → “No Engine” until first enable, then “Pause”).
  func engineSelectorTitle(for engine: AnalysisEngine) -> String {
    if engine == .none {
      return engineHasBeenEnabled ? L10n.text(.enginePause) : L10n.text(.engineNone)
    }
    return engine.title
  }

  /// Symbol for the engine strip control (none → power, then pause after first enable).
  func engineSelectorSymbolName(for engine: AnalysisEngine) -> String {
    if engine == .none {
      return engineHasBeenEnabled ? "pause.fill" : "power"
    }
    return engine.symbolName
  }

  /// Engine used to restore / plot cached analysis while running or paused.
  private var analysisEngineForCachedDisplay: AnalysisEngine? {
    if selectedEngine != .none { return selectedEngine }
    return pausedAnalysisEngine
  }

  private func invalidateChartPointsCache() {
    chartPointsSerial &+= 1
    // chartPoints is computed/memoized — force Canvas observers to re-read the series.
    objectWillChange.send()
  }

  /// Convert lock-free HUD candidates into VM `CandidateMove` rows (for cache / chart).
  private static func candidateMoves(fromAnalyzePayload payload: QixiAnalyzeDisplayPayload) -> [CandidateMove] {
    let display = Array(payload.candidates.lazy.filter { !$0.isPass }.prefix(10))
    return display.enumerated().compactMap { offset, cand in
      guard cand.x >= 0, cand.x < 19, cand.y >= 0, cand.y < 19 else { return nil }
      return CandidateMove(
        x: cand.x,
        y: cand.y,
        rank: offset + 1,
        winrate: Double(cand.winrate),
        visits: Int(clamping: cand.visits),
        scoreMean: Double(cand.scoreMean)
      )
    }
  }

  private static func territoryPoints(fromOwnership ownership: [Float]) -> [TerritoryPoint] {
    guard ownership.count >= 361 else { return [] }
    return ownership.enumerated().compactMap { index, value in
      guard abs(value) >= 0.16 else { return nil }
      return TerritoryPoint(x: index % 19, y: index / 19, ownership: Double(value))
    }
  }

  /// Chart/corner display is always Black's winrate and score lead.
  /// Core publishes side-to-move values — flip when White is to play.
  /// Uses move history (not even/odd ply): SGF/setup lines that start with White invert parity.
  private static func blackSideChartValues(
    winrate: Double,
    scoreMean: Double,
    atPly ply: Int,
    mainLine: [BoardMove]
  ) -> (Double, Double) {
    let moves = Array(mainLine.prefix(max(0, ply)))
    let rootToMove = mainLine.first?.color ?? .black
    let sideToMove = QixiBoardPosition.nextPlayer(after: moves, rootToMove: rootToMove)
    if sideToMove == .black {
      return (winrate, scoreMean)
    }
    return (1.0 - winrate, -scoreMean)
  }

  var variationTree: VariationTree {
    // Must key on currentNodeID: step/jump change only that field. Caching solely on
    // variationTreeSerial left the tree highlight stuck while chart/analysis advanced.
    if let cachedVariationTree,
       cachedVariationTreeSerial == variationTreeSerial,
       cachedVariationTree.currentNodeID == variation.currentNodeID {
      return cachedVariationTree
    }
    let tree = variation.variationTree(qualityDelta: { [self] record in
      variationQualityDelta(for: record)
    })
    cachedVariationTree = tree
    cachedVariationTreeSerial = variationTreeSerial
    return tree
  }

  private func invalidateVariationTreeCache() {
    variationTreeSerial &+= 1
    cachedVariationTree = nil
    // variationTree is a computed property — force observers to re-read colors/topology.
    objectWillChange.send()
  }

  /// Step / chart scrub: update path cursor and bust tree cache (current highlight).
  private func setVariationCurrentOnMainPath(atPly ply: Int) {
    variation.currentNodeID = variationNodeID(onCurrentPathAt: ply)
    // Topology unchanged; still must drop cache so isCurrent / scroll focus update.
    if cachedVariationTree?.currentNodeID != variation.currentNodeID {
      cachedVariationTree = nil
      objectWillChange.send()
    }
  }

  private func resetVariationTree(from moves: [BoardMove], currentPly: Int) {
    variation.reset(from: moves, currentPly: currentPly)
    invalidateVariationTreeCache()
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
    // Path/topology may be unchanged; current highlight and scroll focus must update.
    invalidateVariationTreeCache()
  }

  private func appendVariationMove(_ move: BoardMove) -> String {
    let ply = (variation.records[variation.currentNodeID]?.ply ?? 0) + 1
    let nodeID = variation.appendMove(move, atPly: ply)
    syncCurrentLine(to: nodeID)
    invalidateVariationTreeCache()
    return nodeID
  }

  private func variationQualityDelta(for record: QixiVariationModel.NodeRecord) -> Double? {
    // Prefer live recompute from parent analysis (score-loss when **side-to-move** ≤ 5%).
    // Do NOT sticky-prefer play-time / light-snapshot core deltas: those were often pure
    // winrate-loss and only refreshed for path-capped nodes — which made White-to-move
    // extreme-low dyeing intermittent (sometimes score-loss, sometimes all-green WR-loss).
    if let recomputed = recomputeVariationQualityFromParentCache(record) {
      return recomputed
    }
    // Fallback: core / play-time delta when parent analysis is unavailable.
    if let coreDelta = variation.coreQualityDeltaByNodeID[record.id] {
      return coreDelta
    }
    return nil
  }

  /// Quality of `record.move` vs peers at the parent position (side-to-move polarity).
  private func recomputeVariationQualityFromParentCache(
    _ record: QixiVariationModel.NodeRecord
  ) -> Double? {
    guard let move = record.move else { return nil }
    guard analysisEngineForCachedDisplay != nil else { return nil }
    guard let parentID = record.parentID,
          let parentCache = cachedVariationAnalysis(for: parentID) else {
      return nil
    }
    let peers = parentCache.candidates.filter { $0.visits > 0 }
    var peerWR = peers.map(\.winrate)
    var peerSC = peers.map(\.scoreMean)
    if peerWR.isEmpty, parentCache.visits > 0 {
      peerWR = [parentCache.winrate]
      peerSC = [parentCache.scoreMean]
    }
    guard !peerWR.isEmpty else { return nil }
    // Parent cache winrate is side-to-move at the parent (core convention).
    let parentSTM = parentCache.winrate

    if move.isPass {
      // Pass is not in CandidateMove. Infer mover-perspective WR/score from the child.
      guard let inferred = variationMoveMetricsFromAnalyzedChild(record: record, move: move) else {
        return nil
      }
      return CandidatePalette.qualityDeltaPercent(
        winrate: inferred.winrate,
        scoreMean: inferred.scoreMean,
        peerWinrates: peerWR,
        peerScores: peerSC,
        positionSideToMoveWinrate: parentSTM
      )
    }

    guard let x = move.x, let y = move.y else { return nil }
    // 1) Move was sampled at the parent → true parent-action quality (WR or score mode).
    if let played = peers.first(where: { $0.x == x && $0.y == y }) {
      return CandidatePalette.qualityDeltaPercent(
        winrate: played.winrate,
        scoreMean: played.scoreMean,
        peerWinrates: peerWR,
        peerScores: peerSC,
        positionSideToMoveWinrate: parentSTM
      )
    }
    // 2) Unanalyzed at parent: use child-root eval converted to the mover's side.
    //    Must use child score (not parent root score) so score-loss mode differentiates moves.
    guard let inferred = variationMoveMetricsFromAnalyzedChild(record: record, move: move) else {
      return nil
    }
    return CandidatePalette.qualityDeltaPercent(
      winrate: inferred.winrate,
      scoreMean: inferred.scoreMean,
      peerWinrates: peerWR,
      peerScores: peerSC,
      positionSideToMoveWinrate: parentSTM
    )
  }

  /// Quality of a board move relative to peers at the position that is about to play it.
  /// Uses extreme-low score-loss mode when the **side to move** is ≤ 5%.
  private func qualityDeltaFromLiveCandidates(x: Int, y: Int) -> Double? {
    let rootSTM = analyzeDisplay.rootWinrate
    let visited = candidates.filter { $0.visits > 0 }
    if let played = visited.first(where: { $0.x == x && $0.y == y }), !visited.isEmpty {
      var peerWR = visited.map(\.winrate)
      var peerSC = visited.map(\.scoreMean)
      if let pass = analyzeDisplay.sampledPassMetrics, pass.visits > 0 {
        peerWR.append(pass.winrate)
        peerSC.append(pass.scoreMean)
      }
      return CandidatePalette.qualityDeltaPercent(
        winrate: played.winrate,
        scoreMean: played.scoreMean,
        peerWinrates: peerWR,
        peerScores: peerSC,
        positionSideToMoveWinrate: rootSTM
      )
    }
    var peerWR: [Double] = []
    var peerSC: [Double] = []
    var playedWR: Double?
    var playedSC: Double?
    for pointID in 0..<361 {
      guard let metrics = analyzeDisplay.sampledHUDCandidate(atPointID: pointID),
            metrics.visits > 0 else { continue }
      peerWR.append(metrics.winrate)
      peerSC.append(metrics.scoreMean)
      if metrics.x == x && metrics.y == y {
        playedWR = metrics.winrate
        playedSC = metrics.scoreMean
      }
    }
    if let pass = analyzeDisplay.sampledPassMetrics, pass.visits > 0 {
      peerWR.append(pass.winrate)
      peerSC.append(pass.scoreMean)
    }
    guard let playedWR, let playedSC, !peerWR.isEmpty else { return nil }
    return CandidatePalette.qualityDeltaPercent(
      winrate: playedWR,
      scoreMean: playedSC,
      peerWinrates: peerWR,
      peerScores: peerSC,
      positionSideToMoveWinrate: rootSTM
    )
  }

  /// Quality of pass relative to peers (board + pass) at the current root.
  private func qualityDeltaFromLivePass() -> Double? {
    guard let pass = analyzeDisplay.sampledPassMetrics, pass.visits > 0 else { return nil }
    var peerWR: [Double] = [pass.winrate]
    var peerSC: [Double] = [pass.scoreMean]
    for c in candidates where c.visits > 0 {
      peerWR.append(c.winrate)
      peerSC.append(c.scoreMean)
    }
    for pointID in 0..<361 {
      guard let metrics = analyzeDisplay.sampledHUDCandidate(atPointID: pointID),
            metrics.visits > 0 else { continue }
      peerWR.append(metrics.winrate)
      peerSC.append(metrics.scoreMean)
    }
    return CandidatePalette.qualityDeltaPercent(
      winrate: pass.winrate,
      scoreMean: pass.scoreMean,
      peerWinrates: peerWR,
      peerScores: peerSC,
      positionSideToMoveWinrate: analyzeDisplay.rootWinrate
    )
  }

  private func cachedVariationAnalysis(for nodeID: String) -> QixiCachedAnalysis? {
    guard let engine = analysisEngineForCachedDisplay else { return nil }
    return analysisCache.entry(
      engine: engine,
      cacheKey: positionCacheKey(
        engine: engine,
        moves: variationMoves(to: nodeID),
        setupStones: analysisSetupStones,
        komi: komi,
        rootNoise: rootNoise
      )
    )
  }

  /// Winrate of `move` from the mover's perspective (see `variationMoveMetricsFromAnalyzedChild`).
  private func variationMoveWinrateFromAnalyzedChild(
    record: QixiVariationModel.NodeRecord,
    move: BoardMove
  ) -> Double? {
    variationMoveMetricsFromAnalyzedChild(record: record, move: move)?.winrate
  }

  /// WR + score of `move` from the **mover's** perspective, using the child position's
  /// analysis (cache or live HUD). Child metrics are side-to-move at the child.
  private func variationMoveMetricsFromAnalyzedChild(
    record: QixiVariationModel.NodeRecord,
    move: BoardMove
  ) -> (winrate: Double, scoreMean: Double)? {
    let childMoves = variationMoves(to: record.id)
    let childWinrate: Double
    let childScore: Double
    if let childCache = cachedVariationAnalysis(for: record.id), childCache.visits > 0 {
      childWinrate = childCache.winrate
      childScore = childCache.scoreMean
    } else if record.id == variation.currentNodeID, analyzeDisplay.rootVisits > 0 {
      // Real-time path: engine is analyzing the new situation right now.
      childWinrate = analyzeDisplay.rootWinrate
      childScore = analyzeDisplay.rootScoreMean
    } else {
      return nil
    }
    let childNextPlayer = QixiBoardPosition.nextPlayer(after: childMoves)
    // Child root metrics are side-to-move at the child; convert to the mover's side.
    if childNextPlayer == move.color {
      return (childWinrate, childScore)
    }
    return (1.0 - childWinrate, -childScore)
  }

  /// Write the current root's analysis into the cache (parent position, before a play).
  private func snapshotCurrentPositionAnalysisForVariationDye() {
    guard selectedEngine != .none else { return }
    let visits = Int(clamping: analyzeDisplay.rootVisits)
    guard visits > 0 || !candidates.isEmpty || !analyzeDisplay.overlays.isEmpty else { return }
    guard let cacheKey = currentAnalysisCacheKey(for: selectedEngine) else { return }
    var cands = candidates
    if cands.isEmpty {
      // Sample live HUD metrics so parent "best" is available for post-play dyeing.
      var built: [CandidateMove] = []
      built.reserveCapacity(10)
      for pointID in 0..<361 {
        guard let m = analyzeDisplay.sampledHUDCandidate(atPointID: pointID), m.visits > 0 else {
          continue
        }
        built.append(
          CandidateMove(
            x: m.x,
            y: m.y,
            rank: built.count + 1,
            winrate: m.winrate,
            visits: m.visits,
            scoreMean: m.scoreMean
          )
        )
        if built.count >= 10 { break }
      }
      cands = built
    }
    let existing = analysisCache.entry(engine: selectedEngine, cacheKey: cacheKey)
    analysisCache.put(
      engine: selectedEngine,
      cacheKey: cacheKey,
      positionKey: cacheKey,
      winrate: visits > 0 ? analyzeDisplay.rootWinrate : currentWinrate,
      scoreMean: visits > 0 ? analyzeDisplay.rootScoreMean : currentScoreMean,
      visits: max(visits, existing?.visits ?? 0),
      candidates: cands.isEmpty ? (existing?.candidates ?? []) : cands,
      territory: territory.isEmpty ? (existing?.territory ?? []) : territory
    )
  }

  /// After live analysis of the current root, dye the current move node when it was not
  /// sampled at the parent. Uses parent baseline vs real-time child (new situation) eval.
  /// Refreshes as visits improve so the tree tracks the engine.
  /// Includes pass (previously left permanently white).
  private func refreshUnanalyzedMoveQualityDyeFromLiveChild() {
    let nodeID = variation.currentNodeID
    guard let record = variation.records[nodeID],
          let move = record.move else { return }
    guard let parentID = record.parentID,
          let parentCache = cachedVariationAnalysis(for: parentID) else { return }

    let peers = parentCache.candidates.filter { $0.visits > 0 }
    var peerWR = peers.map(\.winrate)
    var peerSC = peers.map(\.scoreMean)
    if peerWR.isEmpty, parentCache.visits > 0 {
      peerWR = [parentCache.winrate]
      peerSC = [parentCache.scoreMean]
    }
    guard !peerWR.isEmpty else { return }

    let delta: Double?
    let parentSTM = parentCache.winrate
    if move.isPass {
      guard let inferred = variationMoveMetricsFromAnalyzedChild(record: record, move: move) else {
        return
      }
      delta = CandidatePalette.qualityDeltaPercent(
        winrate: inferred.winrate,
        scoreMean: inferred.scoreMean,
        peerWinrates: peerWR,
        peerScores: peerSC,
        positionSideToMoveWinrate: parentSTM
      )
    } else if let x = move.x, let y = move.y,
              let played = peers.first(where: { $0.x == x && $0.y == y }) {
      // True parent-action quality (WR-loss or extreme-low score-loss).
      delta = CandidatePalette.qualityDeltaPercent(
        winrate: played.winrate,
        scoreMean: played.scoreMean,
        peerWinrates: peerWR,
        peerScores: peerSC,
        positionSideToMoveWinrate: parentSTM
      )
    } else {
      guard let inferred = variationMoveMetricsFromAnalyzedChild(record: record, move: move) else {
        return
      }
      delta = CandidatePalette.qualityDeltaPercent(
        winrate: inferred.winrate,
        scoreMean: inferred.scoreMean,
        peerWinrates: peerWR,
        peerScores: peerSC,
        positionSideToMoveWinrate: parentSTM
      )
    }
    guard let delta else { return }

    if let previous = variation.coreQualityDeltaByNodeID[nodeID], abs(previous - delta) < 0.05 {
      return
    }
    variation.coreQualityDeltaByNodeID[nodeID] = delta
    invalidateVariationTreeCache()
  }

  private func cachedChartAnalysis(at ply: Int) -> QixiCachedAnalysis? {
    guard let engine = analysisEngineForCachedDisplay, ply >= 0, ply <= mainLine.count else { return nil }
    let moves = Array(mainLine.prefix(ply))
    let key = positionCacheKey(
      engine: engine,
      moves: moves,
      setupStones: analysisSetupStones,
      komi: komi,
      rootNoise: rootNoise
    )
    return analysisCache.entry(engine: engine, cacheKey: key)
  }

  func selectEngine(_ engine: AnalysisEngine) {
    // Model switching must always respond. Only hard I/O / memory jobs may refuse.
    // During an in-flight engine switch the user must still be able to pick another model.
    if let job = activeBlockingJob {
      switch job.kind {
      case .switchingEngine, .restoringState:
        break // supersede
      case .exportingState, .importingState, .installingModel, .memoryUnload, .memoryReload:
        return
      }
    } else if isBackendInteractionBlocked {
      return
    }
    // Same engine with no live poll (e.g. after New cancelled the HUD task) must restart.
    if engine == selectedEngine {
      if engine != .none, analysisTask == nil {
        startAnalysis(engine: engine, assumesEngineAlreadyLoaded: true)
      }
      return
    }
    // Drop any prior switching/restoring barrier so a new selection cannot stack forever
    // and leave the UI permanently non-interactive.
    clearSupersededEngineSwitchBarriers()
    let previousEngine = selectedEngine

    // Pause: stop analysis / unload, but keep prior painted results on screen.
    if engine == .none, previousEngine != .none {
      beginEnginePause(from: previousEngine)
      return
    }

    if engine != .none {
      engineHasBeenEnabled = true
      pausedAnalysisEngine = nil
    }

    let switchWallStart = ContinuousClock.now
    let transitionToken = beginBackendTransition(.switchingEngine)
    // Capture wall-clock from tap → unlock for diagnosis (see appendSwitchTimingLine).
    engineSwitchWallStart = switchWallStart
    engineSwitchTarget = engine
    switchMonitor.begin(from: previousEngine, to: engine)
    switchMonitor.mark("barrier_begin", detail: "token")
    refreshSwitchMonitorSnapshot()
    // Debounced UI snapshot only — do not block the switch on a synchronous save.
    persistence.saveSoon(reason: "beforeEngineSwitch")
    analysisTask?.cancel()
    analysisGeneration += 1
    planeBSettlementGeneration &+= 1
    planeBNavInFlight = 0
    lastAppliedAnalyzeCoreRoot = nil
    lastHUDCacheVisits = -1
    lastHUDCacheRoot = UInt32.max
    lastHUDCacheAt = nil
    lastNextMoveDecorationKey = nil
    memoizedCurrentAnalysisCacheKey = nil
    analyzeDisplay.clear()
    refreshNextMoveDecoration()
    selectedEngine = engine
    // Do not show cached analysis during a switch — it looks "ready" while play is still blocked
    // and while the previous model may still be the one searching.
    clearVisibleAnalysisAndRefreshAnchor()
    hermesStatus = engine == .none ? .ready : .loading
    if let coreBackendService {
      if engine == .none {
        // Cold “No Engine” (never enabled) — nothing to preserve.
        submitCoreEngineSelection(engine, reason: "coreEngineUnloaded") { [weak self] success in
          guard let self else { return }
          self.finishBackendTransition(transitionToken)
          guard self.selectedEngine == .none else { return }
          if !success {
            let failure = self.lastEngineError
            self.selectedEngine = previousEngine
            self.hermesStatus = previousEngine == .none ? .ready : .loading
            self.persistence.saveSoon(reason: "engineSelectionRolledBack")
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
          self.loadedEngine = .none
          self.lastEngineError = nil
          self.hermesStatus = .ready
          self.logEngineSwitchWallComplete(engine: .none, success: true)
          self.persistence.saveSoon(reason: "engineNone")
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

  /// Pause analysis: stop searching and unload the model, keep prior results visible.
  private func beginEnginePause(from previousEngine: AnalysisEngine) {
    engineHasBeenEnabled = true
    pausedAnalysisEngine = previousEngine
    // Pause is not a model-switch measurement — end any live switch-monitor session
    // immediately so the +ms ticker cannot keep running while analysis is paused.
    endSwitchMonitorLiveSession(success: true)
    let transitionToken = beginBackendTransition(.switchingEngine)
    persistence.saveSoon(reason: "beforeEnginePause")
    analysisTask?.cancel()
    analysisGeneration += 1
    planeBSettlementGeneration &+= 1
    planeBNavInFlight = 0
    lastAppliedAnalyzeCoreRoot = nil
    lastHUDCacheVisits = -1
    lastHUDCacheRoot = UInt32.max
    lastHUDCacheAt = nil
    memoizedCurrentAnalysisCacheKey = nil
    // Intentionally keep analyzeDisplay / candidates / territory / chart.
    selectedEngine = .none
    // Ready immediately: search is stopped from the UI's perspective; unload is background.
    hermesStatus = .ready
    invalidateChartPointsCache()
    refreshSwitchMonitorSnapshot()

    if let coreBackendService {
      submitCoreEngineSelection(.none, reason: "coreEnginePaused") { [weak self] success in
        guard let self else { return }
        self.finishBackendTransition(transitionToken)
        // Always clear any residual live switch session after unload settles.
        self.endSwitchMonitorLiveSession(success: success)
        guard self.selectedEngine == .none else { return }
        if !success {
          let failure = self.lastEngineError
          self.selectedEngine = previousEngine
          self.pausedAnalysisEngine = nil
          self.hermesStatus = .loading
          self.persistence.saveSoon(reason: "enginePauseRolledBack")
          self.startCoreSnapshotPolling(
            engine: previousEngine,
            assumesEngineAlreadyLoaded: true,
            coreBackendService: coreBackendService,
            preservedEngineError: failure
          )
          return
        }
        self.loadedEngine = .none
        self.lastEngineError = nil
        self.hermesStatus = .ready
        self.persistence.saveSoon(reason: "enginePaused")
        self.recordRuntimeDiagnostic(
          event: "enginePaused",
          success: true,
          message: "Paused analysis; prior results retained."
        )
        self.refreshSwitchMonitorSnapshot()
      }
      return
    }

    persistence.saveNow(reason: "enginePaused")
    analysisTask = Task { [weak self, analysisService] in
      guard let self else { return }
      do {
        await self.waitForCoreMutationDrain()
        _ = try await analysisService.setEngine(.none)
        try Task.checkCancellation()
        self.finishBackendTransition(transitionToken)
        self.endSwitchMonitorLiveSession(success: true)
        guard self.selectedEngine == .none else { return }
        self.loadedEngine = .none
        self.lastEngineError = nil
        self.hermesStatus = .ready
        self.recordRuntimeDiagnostic(
          event: "enginePaused",
          success: true,
          message: "Paused analysis; prior results retained."
        )
        self.refreshSwitchMonitorSnapshot()
      } catch {
        self.finishBackendTransition(transitionToken)
        self.endSwitchMonitorLiveSession(success: false)
        guard !Task.isCancelled else { return }
        guard self.selectedEngine == .none else { return }
        let failure = self.localizedEngineError(error, fallbackKey: .engineErrorUnloadFailed)
        self.lastEngineError = failure
        self.hermesStatus = .offline
        self.recordRuntimeDiagnostic(event: "enginePauseFailed", success: false, message: String(describing: error))
        self.selectedEngine = previousEngine
        self.pausedAnalysisEngine = nil
        self.persistence.saveNow(reason: "enginePauseRolledBack")
        self.startAnalysis(
          engine: previousEngine,
          assumesEngineAlreadyLoaded: true,
          preservedEngineError: failure
        )
      }
    }
  }

  /// Stops the switch-monitor live +ms ticker if it is running (pause / unload paths).
  private func endSwitchMonitorLiveSession(success: Bool) {
    if switchMonitor.isSwitching {
      switchMonitor.finish(success: success, wallMs: switchMonitor.elapsedMs)
    }
    engineSwitchWallStart = nil
    engineSwitchTarget = nil
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

    // Always start the HUD loop immediately. Waiting until model load finished was the
    // main reason users only saw analysis after 10k+ visits — search ran unbound while
    // the main thread was still inside setEngine / tree rebuild.
    if !assumesEngineAlreadyLoaded {
      hermesStatus = .loading
      submitCoreEngineSelection(engine, reason: "coreEngineSelected") { [weak self] success in
        guard let self else { return }
        // Always release the barrier for this attempt, even if the selection was superseded.
        self.finishBackendTransition(transitionToken)
        guard self.selectedEngine == engine else { return }
        // If a newer poll generation already replaced this one, do not restart work.
        guard self.analysisGeneration == generation else { return }
        if !success {
          let failure = self.lastEngineError
          self.analysisTask?.cancel()
          self.analysisGeneration += 1
          self.hermesStatus = .offline
          self.lastEngineError = failure ?? self.lastEngineError
          self.logEngineSwitchWallComplete(engine: engine, success: false)
          if let rollbackEngine, rollbackEngine != engine {
            self.selectedEngine = rollbackEngine
            self.persistence.saveNow(reason: "engineSelectionRolledBack")
            if rollbackEngine != .none {
              self.startCoreSnapshotPolling(
                engine: rollbackEngine,
                assumesEngineAlreadyLoaded: true,
                coreBackendService: coreBackendService,
                preservedEngineError: failure
              )
            } else {
              self.hermesStatus = .ready
            }
          }
          return
        }
        self.switchMonitor.mark("mutation_ok", detail: engine.rawValue)
        self.loadedEngine = engine
        self.lastEngineError = nil
        // Model switch replaces the core store (per-model isolation). Old `.node(id)`
        // bindings and any HUD residue from another engine must not survive.
        self.invalidateStaleCoreNodeReferencesAfterStoreClone()
        self.lastHUDCacheVisits = -1
        self.lastHUDCacheRoot = UInt32.max
        self.lastHUDCacheAt = nil
        self.memoizedCurrentAnalysisCacheKey = nil
        self.analyzeDisplay.clear()
        // Mark ready BEFORE painting. paintAnalyzeHUD used to demote ready→loading when
        // the first post-switch frame still had zero visits.
        self.hermesStatus = .ready
        self.switchMonitor.mark("hermes_ready")
        // Paint only this engine's plane (fresh path-clone starts at 0 visits).
        // Never restore another engine's chart cache into the live HUD here.
        self.forceApplyLatestAnalyzeDisplay(
          engine: engine,
          preservedEngineError: preservedEngineError
        )
        if self.hermesStatus != .ready { self.hermesStatus = .ready }
        self.refreshSwitchMonitorSnapshot()
        self.logEngineSwitchWallComplete(engine: engine, success: true)
      }
      // Fall through and start HUD polling now (while load is in flight).
    } else {
      finishBackendTransition(transitionToken)
    }

    analysisTask = Task { [weak self, coreBackendService] in
      guard let self else { return }
      var structureRefreshTask: Task<Void, Never>?
      defer { structureRefreshTask?.cancel() }
      do {
        var lastHUDRevision: UInt64 = 0
        var lastStructureRoot: UInt32 = UInt32.max
        var lastStructureAt = ContinuousClock.Instant.now - .seconds(10)
        // Structure/tree JSON must NEVER block the HUD path.
        let structureMinInterval: Duration = .milliseconds(500)

        while true {
          try Task.checkCancellation()
          guard generation == self.analysisGeneration, self.selectedEngine == engine else { return }
          let t0 = ContinuousClock.now

          // Plane A: sync lock-free probes — no actor hop, no structure JSON.
          let published = coreBackendService.publishedAnalyzeRevisionSync()
          if published != lastHUDRevision {
            if let payload = coreBackendService.tryLoadAnalyzeDisplaySync() {
              if self.shouldAcceptAnalyzeCoreRoot(payload.root) {
                lastHUDRevision = payload.revision
                self.paintAnalyzeHUD(
                  payload,
                  engine: engine,
                  preservedEngineError: preservedEngineError
                )

                let rootChanged = payload.root != lastStructureRoot
                let earlyEnough = payload.rootVisits >= 4 || payload.candidateCount > 0
                // After root switch, defer structure a bit so HUD/play stay on the hot path.
                // Structure JSON must never run on the first frame after a jump.
                let structureDue = earlyEnough &&
                  self.planeBNavInFlight == 0 &&
                  (rootChanged
                    ? (t0 - lastStructureAt) >= .milliseconds(250)
                    : (t0 - lastStructureAt) >= structureMinInterval)
                if structureDue {
                  lastStructureRoot = payload.root
                  lastStructureAt = t0
                  let structureGeneration = generation
                  structureRefreshTask?.cancel()
                  // Fetch off the HUD loop's tight MainActor turn; apply results back on MainActor.
                  structureRefreshTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                      let result = try await coreBackendService.latestCoreSnapshot()
                      try Task.checkCancellation()
                      await MainActor.run {
                        guard structureGeneration == self.analysisGeneration,
                              self.selectedEngine == engine else { return }
                        guard self.planeBNavInFlight == 0 else { return }
                        guard self.shouldAcceptAnalyzeCoreRoot(result.currentRoot) else { return }
                        self.noteAcceptedAnalyzeCoreRoot(result.currentRoot)
                        self.applyCoreBackendResult(
                          result,
                          reason: "snapshotPollStructure",
                          allowWhileMutationsPending: false
                        )
                      }
                    } catch is CancellationError {
                      return
                    } catch {
                      // Structure is best-effort; HUD remains authoritative for analysis.
                    }
                  }
                }
              }
            }
          }

          let elapsed = ContinuousClock.now - t0
          // Early phase / still loading: poll aggressively so first visits paint ASAP.
          let earlyPhase = self.analyzeDisplay.rootVisits < 128 || self.hermesStatus == .loading
          let budget: Duration = earlyPhase ? .milliseconds(1) : .nanoseconds(8_333_333)
          if elapsed < budget {
            try await Task.sleep(for: budget - elapsed)
          } else {
            await Task.yield()
          }
        }
      } catch {
        guard !Task.isCancelled else { return }
        guard generation == self.analysisGeneration, self.selectedEngine == engine else { return }
        self.lastEngineError = self.localizedEngineError(error, fallbackKey: .engineErrorAnalysisFailed)
        self.hermesStatus = .offline
        self.recordRuntimeDiagnostic(
          event: "coreSnapshotPollingFailed",
          success: false,
          message: String(describing: error)
        )
      }
    }
  }

  /// Immediate lock-free HUD sample (used right when the model becomes ready).
  private func forceApplyLatestAnalyzeDisplay(
    engine: AnalysisEngine,
    preservedEngineError: String?
  ) {
    guard let core = coreBackendService else { return }
    guard let payload = core.tryLoadAnalyzeDisplaySync() else { return }
    // After engine load, trust the published root so the first frame is never gated out.
    if payload.root != UInt32.max {
      coreCurrentRootID = payload.root
      planeBNavInFlight = 0
    }
    paintAnalyzeHUD(payload, engine: engine, preservedEngineError: preservedEngineError)
  }

  /// Append UI wall-clock to the same timing file core writes (`$TMPDIR/qixi-switch-timing.log`).
  private func logEngineSwitchWallComplete(engine: AnalysisEngine, success: Bool) {
    guard engineSwitchTarget == engine, let start = engineSwitchWallStart else { return }
    let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
    let line =
      "[qixi-switch] UI_wall tap_to_unlock_ms=\(ms) engine=\(engine.rawValue) success=\(success) " +
      "loadedEngine=\(loadedEngine.rawValue) hermes=\(hermesStatus.telemetryValue)"
    print(line)
    recordRuntimeDiagnostic(event: "engineSwitchWall", success: success, message: line)
    if let tmp = FileManager.default.temporaryDirectory.path as String? {
      let url = URL(fileURLWithPath: tmp).appendingPathComponent("qixi-switch-timing.log")
      if let data = (line + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
          defer { try? handle.close() }
          _ = try? handle.seekToEnd()
          try? handle.write(contentsOf: data)
        } else {
          try? data.write(to: url)
        }
      }
    }
    switchMonitor.finish(success: success, wallMs: ms)
    refreshSwitchMonitorSnapshot()
    engineSwitchWallStart = nil
    engineSwitchTarget = nil
  }

  func noteEngineSwitchPhase(_ phase: String, detail: String?) {
    if phase == "setEngine_status", let detail {
      // detail like "wall=1234ms state=..."
      var wall = 0
      if let range = detail.range(of: "wall="),
         let msPart = detail[range.upperBound...].split(separator: "ms").first,
         let parsed = Int(msPart) {
        wall = parsed
      }
      switchMonitor.noteSetEngineStatus(detail, wallMs: wall)
    } else {
      switchMonitor.mark(phase, detail: detail)
    }
    refreshSwitchMonitorSnapshot()
  }

  private func refreshSwitchMonitorSnapshot() {
    switchMonitor.refreshSnapshot(
      selected: selectedEngine,
      loaded: loadedEngine,
      hermes: hermesStatus,
      boardBlocked: isBoardPlayBlocked,
      rootVisits: Int(clamping: analyzeDisplay.rootVisits)
    )
  }

  /// After a model switch the core store is a path clone with renumbered NodeIds.
  /// Previous `.node(id)` mappings would postNavSwitchRoot into the wrong (or OOB) nodes.
  private func invalidateStaleCoreNodeReferencesAfterStoreClone() {
    var next = variation.coreRootReferenceByNodeID
    for (id, ref) in variation.coreRootReferenceByNodeID {
      guard case .node = ref else { continue }
      if let hash = Self.lineageHash(fromVariationNodeID: id) {
        next[id] = .lineage(hash)
      } else {
        // Local optimistic ids (vN) — clear until structure rebinds.
        next.removeValue(forKey: id)
      }
    }
    variation.coreRootReferenceByNodeID = next
  }

  /// Bind variation tree to the new path-cloned store without blocking the switch UI.
  private func scheduleStructureRefreshAfterEngineSwitch(
    engine: AnalysisEngine,
    generation: Int,
    coreBackendService: any QixiCoreBackendService
  ) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await coreBackendService.latestCoreSnapshot()
        await MainActor.run {
          guard generation == self.analysisGeneration, self.selectedEngine == engine else { return }
          guard self.loadedEngine == engine else { return }
          if result.currentRoot != UInt32.max {
            self.coreCurrentRootID = result.currentRoot
          }
          self.applyCoreBackendResult(
            result,
            reason: "snapshotAfterEngineSwitch",
            allowWhileMutationsPending: true
          )
        }
      } catch {
        // Best-effort; HUD remains authoritative until the next structure poll.
      }
    }
  }

  private func paintAnalyzeHUD(
    _ payload: QixiAnalyzeDisplayPayload,
    engine: AnalysisEngine,
    preservedEngineError: String?
  ) {
    guard selectedEngine == engine else { return }
    // Never paint another model's HUD after a switch (old worker can still publish briefly).
    guard loadedEngine == engine else { return }
    analyzeDisplay.apply(payload)
    noteAcceptedAnalyzeCoreRoot(payload.root)
    if let preservedEngineError {
      lastEngineError = preservedEngineError
    }
    applyLiveEngineMetricsFromHUD(payload)
    refreshNextMoveDecoration(includeChildCache: false)
    syncHermesStatusWithLiveAnalysis(
      hasLiveMetrics: payload.rootVisits > 0 || payload.candidateCount > 0
    )
    refreshSwitchMonitorSnapshot()
  }

  func noteCoreEngineSelectionCommitted(_ engine: AnalysisEngine) {
    loadedEngine = engine
  }

  /// Metrics-only result after setEngine — no tree JSON (keeps switch + board unlock fast).
  func makeEngineSelectionResult(engine: AnalysisEngine) -> QixiCoreBackendResult {
    if let payload = coreBackendService?.tryLoadAnalyzeDisplaySync() {
      return QixiCoreBackendResult(
        requestId: 0,
        backendEpoch: max(payload.backendEpoch, coreBackendEpoch),
        revision: max(payload.revision, coreRevision),
        ok: true,
        message: "engine selection committed",
        currentRoot: payload.root == UInt32.max ? coreCurrentRootID : payload.root,
        engineState: engine == .none ? "none" : "ready",
        storeState: "ready",
        committedUiIntentId: nil,
        snapshot: nil
      )
    }
    return QixiCoreBackendResult(
      requestId: 0,
      backendEpoch: coreBackendEpoch &+ 1,
      revision: coreRevision &+ 1,
      ok: true,
      message: "engine selection committed",
      currentRoot: coreCurrentRootID,
      engineState: engine == .none ? "none" : "ready",
      storeState: "ready",
      committedUiIntentId: nil,
      snapshot: nil
    )
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
    guard !isBoardPlayBlocked else { return }
    // Scrub/jump is latest-wins (supersede). Only play/pass serialize on planeBNavInFlight.
    let newPly = min(max(0, currentPly + delta), mainLine.count)
    // No-op at ends must not clear analysis or gate the HUD.
    guard newPly != currentPly else { return }
    invalidateActiveAnalysisForPositionChange()
    let oldPly = currentPly
    currentPly = newPly
    setVariationCurrentOnMainPath(atPly: currentPly)
    clearBoardRecognitionPreview()
    let usingCore = coreBackendService != nil
    let hadCache = restoreCachedAnalysisForCurrentPosition()
    beginPlaneBNavGate(usingCore: usingCore, clearDisplay: !hadCache)
    if !hadCache {
      if selectedEngine == .none {
        // Paused with no prior analysis at this ply — drop overlays.
        clearVisibleAnalysisAndRefreshAnchor()
      } else {
        // Cache miss: blank only the lock-free plane; board stones already match UI ply.
        analyzeDisplay.clear()
        refreshNextMoveDecoration()
        refreshLocalChartAnchor()
      }
    }
    persistence.saveSoon(reason: "step")
    if coreBackendService != nil {
      if let target = variation.coreRootReferenceByNodeID[variation.currentNodeID] {
        postNavJump(target, reason: "coreStep")
      } else {
        let actualSteps = abs(newPly - oldPly)
        guard actualSteps > 0 else {
          finishPlaneBNavGate(success: true)
          return
        }
        // FIFO undo/redo — settle via lock-free HUD, never block on structure JSON.
        postNavJumpFIFO(
          newPly < oldPly
            ? .undo(steps: actualSteps, expectedBackendEpoch: 0)
            : .redo(steps: actualSteps, expectedBackendEpoch: 0),
          reason: "coreStep"
        )
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  func jump(to ply: Int) {
    guard !isBoardPlayBlocked else { return }
    let newPly = min(max(0, ply), mainLine.count)
    guard newPly != currentPly else { return }
    let oldPly = currentPly
    invalidateActiveAnalysisForPositionChange()
    currentPly = newPly
    setVariationCurrentOnMainPath(atPly: currentPly)
    clearBoardRecognitionPreview()
    let usingCore = coreBackendService != nil
    let hadCache = restoreCachedAnalysisForCurrentPosition()
    beginPlaneBNavGate(usingCore: usingCore, clearDisplay: !hadCache)
    if !hadCache {
      if selectedEngine == .none {
        clearVisibleAnalysisAndRefreshAnchor()
      } else {
        analyzeDisplay.clear()
        refreshNextMoveDecoration()
        refreshLocalChartAnchor()
      }
    }
    persistence.saveSoon(reason: "jump")
    if coreBackendService != nil {
      if let target = variation.coreRootReferenceByNodeID[variation.currentNodeID] {
        postNavJump(target, reason: "coreJump")
      } else {
        let actualSteps = abs(newPly - oldPly)
        guard actualSteps > 0 else {
          finishPlaneBNavGate(success: true)
          return
        }
        postNavJumpFIFO(
          newPly < oldPly
            ? .undo(steps: actualSteps, expectedBackendEpoch: 0)
            : .redo(steps: actualSteps, expectedBackendEpoch: 0),
          reason: "coreJump"
        )
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  func jump(toVariationNode nodeID: String) {
    guard !isBoardPlayBlocked else { return }
    guard variation.records[nodeID] != nil else { return }
    guard nodeID != variation.currentNodeID else { return }
    invalidateActiveAnalysisForPositionChange()
    syncCurrentLine(to: nodeID, includePrimaryContinuation: true)
    clearBoardRecognitionPreview()
    let usingCore = coreBackendService != nil
    let hadCache = restoreCachedAnalysisForCurrentPosition()
    beginPlaneBNavGate(usingCore: usingCore, clearDisplay: !hadCache)
    if !hadCache {
      if selectedEngine == .none {
        clearVisibleAnalysisAndRefreshAnchor()
      } else {
        analyzeDisplay.clear()
        refreshNextMoveDecoration()
        refreshLocalChartAnchor()
      }
    }
    persistence.saveSoon(reason: "variationJump")
    if coreBackendService != nil {
      if let target = variation.coreRootReferenceByNodeID[nodeID] {
        postNavJump(target, reason: "coreVariationJump")
      } else if let hash = Self.lineageHash(fromVariationNodeID: nodeID) {
        postNavJumpFIFO(
          .jumpToNode(.lineage(hash), expectedBackendEpoch: 0),
          reason: "coreVariationJump"
        )
      } else {
        finishPlaneBNavGate(success: false)
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  private static func lineageHash(fromVariationNodeID nodeID: String) -> UInt64? {
    guard nodeID.hasPrefix("l"), let value = UInt64(nodeID.dropFirst()) else { return nil }
    return value
  }

  func passMove() {
    guard !isBoardPlayBlocked else { return }
    // Plane B is single-slot latest-wins — serialize plays so double-tap cannot drop a stone.
    guard planeBNavInFlight == 0 || coreBackendService == nil else { return }
    markSessionDirty()
    invalidateActiveAnalysisForPositionChange()
    let prePlayNodeID = variation.currentNodeID
    let prePlayPly = currentPly
    let prePlayMainLine = mainLine
    let rootBefore = coreCurrentRootID
    let intentID = nextCoreIntentID()
    // Same dye path as board plays: capture parent quality *before* overlays clear.
    // Prefer live pass candidate when engine sampled pass; otherwise child-inferred dye
    // fills in via refreshUnanalyzedMoveQualityDyeFromLiveChild after analysis.
    let passQualityDelta = qualityDeltaFromLivePass()
    snapshotCurrentPositionAnalysisForVariationDye()
    _ = appendVariationMove(BoardMove(pass: nextColor))
    let optimisticNodeID = variation.currentNodeID
    variation.coreRootReferenceByNodeID[optimisticNodeID] = .intent(intentID)
    if let passQualityDelta {
      variation.coreQualityDeltaByNodeID[optimisticNodeID] = passQualityDelta
      invalidateVariationTreeCache()
    }
    clearBoardRecognitionPreview()
    beginPlaneBNavGate(usingCore: coreBackendService != nil, clearDisplay: false)
    // Prefer cached analysis of the new position; only blank if none.
    if !restoreCachedAnalysisForCurrentPosition() {
      analyzeDisplay.clear()
      refreshNextMoveDecoration()
      refreshLocalChartAnchor()
    }
    persistence.saveSoon(reason: "passMove")
    if let core = coreBackendService {
      let settlementGen = planeBSettlementGeneration
      let posted = core.postNavPlaySync(move: 361, uiIntentId: intentID)
      Task { [weak self] in
        await self?.awaitPlaneBPlaySettlement(
          core: core,
          posted: posted,
          rootBefore: rootBefore,
          optimisticNodeID: optimisticNodeID,
          restoreNodeID: prePlayNodeID,
          restoreMainLine: prePlayMainLine,
          restorePly: prePlayPly,
          settlementGeneration: settlementGen
        )
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  func play(at x: Int, y: Int) {
    guard !isBoardPlayBlocked else { return }
    // Plane B is single-slot latest-wins — serialize plays so double-tap cannot drop a stone.
    guard planeBNavInFlight == 0 || coreBackendService == nil else { return }
    guard x >= 0, x < 19, y >= 0, y < 19 else { return }
    markSessionDirty()
    guard QixiBoardPosition.isLegalMove(
      after: boardMoves,
      setupStones: analysisSetupStones,
      x: x,
      y: y,
      color: nextColor
    ) else { return }
    invalidateActiveAnalysisForPositionChange()
    let prePlayNodeID = variation.currentNodeID
    let prePlayPly = currentPly
    let prePlayMainLine = mainLine
    let rootBefore = coreCurrentRootID
    let intentID = nextCoreIntentID()
    // Capture dye vs best candidate *before* overlays clear (parent-action quality).
    let moveQualityDelta = qualityDeltaFromLiveCandidates(x: x, y: y)
    // Snapshot parent analysis into the LRU *before* the board advances so unanalyzed
    // plays can later dye from (child real-time eval − parent best/root).
    snapshotCurrentPositionAnalysisForVariationDye()
    _ = appendVariationMove(BoardMove(color: nextColor, x: x, y: y))
    let optimisticNodeID = variation.currentNodeID
    variation.coreRootReferenceByNodeID[optimisticNodeID] = .intent(intentID)
    if let moveQualityDelta {
      variation.coreQualityDeltaByNodeID[optimisticNodeID] = moveQualityDelta
      invalidateVariationTreeCache()
    }
    clearBoardRecognitionPreview()
    beginPlaneBNavGate(usingCore: coreBackendService != nil, clearDisplay: false)
    // Keep prior overlays only if we already have analysis for this new position.
    if !restoreCachedAnalysisForCurrentPosition() {
      analyzeDisplay.clear()
      refreshNextMoveDecoration()
      refreshLocalChartAnchor()
    }
    persistence.saveSoon(reason: "play")
    if let core = coreBackendService {
      let move = UInt32(coreMoveIndex(x: x, y: y))
      let settlementGen = planeBSettlementGeneration
      // Sync post — no actor hop on the play critical path.
      let posted = core.postNavPlaySync(move: move, uiIntentId: intentID)
      Task { [weak self] in
        await self?.awaitPlaneBPlaySettlement(
          core: core,
          posted: posted,
          rootBefore: rootBefore,
          optimisticNodeID: optimisticNodeID,
          restoreNodeID: prePlayNodeID,
          restoreMainLine: prePlayMainLine,
          restorePly: prePlayPly,
          settlementGeneration: settlementGen
        )
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  /// `postNavPlay` only means the intent was published (latest-wins), not that core applied it.
  /// Settle exclusively via lock-free HUD (target <100 ms). Never block on tree JSON.
  private func awaitPlaneBPlaySettlement(
    core: any QixiCoreBackendService,
    posted: Bool,
    rootBefore: UInt32,
    optimisticNodeID: String,
    restoreNodeID: String,
    restoreMainLine: [BoardMove],
    restorePly: Int,
    settlementGeneration: UInt64
  ) async {
    if !posted {
      await MainActor.run {
        guard settlementGeneration == self.planeBSettlementGeneration else { return }
        self.rollbackOptimisticPlay(
          optimisticNodeID: optimisticNodeID,
          restoreNodeID: restoreNodeID,
          restoreMainLine: restoreMainLine,
          restorePly: restorePly
        )
        self.finishPlaneBNavGate(success: false)
      }
      return
    }
    // Lock-free only. Previous path called latestCoreSnapshot every 8 ms and routinely
    // spent hundreds of ms before the first paint after a move.
    let deadline = ContinuousClock.now + .milliseconds(100)
    var lastYield = ContinuousClock.now
    while ContinuousClock.now < deadline {
      if let payload = core.tryLoadAnalyzeDisplaySync(),
         payload.root != rootBefore,
         payload.root != UInt32.max {
        await MainActor.run {
          guard settlementGeneration == self.planeBSettlementGeneration else { return }
          self.coreCurrentRootID = payload.root
          // Bind optimistic variation node to core node id for future O(1) jumps.
          self.variation.coreRootReferenceByNodeID[optimisticNodeID] = .node(payload.root)
          self.finishPlaneBNavGate(success: true)
          // Paint immediately — do not wait for the next 1–8 ms HUD loop tick.
          self.paintAnalyzeHUD(
            payload,
            engine: self.selectedEngine,
            preservedEngineError: self.lastEngineError
          )
        }
        return
      }
      // Yield often enough for Swift concurrency + core worker progress; stay under 100 ms.
      if ContinuousClock.now - lastYield >= .milliseconds(1) {
        lastYield = ContinuousClock.now
        await Task.yield()
      }
    }
    await MainActor.run {
      guard settlementGeneration == self.planeBSettlementGeneration else { return }
      self.rollbackOptimisticPlay(
        optimisticNodeID: optimisticNodeID,
        restoreNodeID: restoreNodeID,
        restoreMainLine: restoreMainLine,
        restorePly: restorePly
      )
      self.finishPlaneBNavGate(success: false)
    }
  }

  /// Plane B: O(1) switch when node id known; lineage/intent fall back to FIFO + lock-free settle.
  /// Caller must already have begun the Plane B nav gate (do not clear restored HUD here).
  private func postNavJump(_ target: QixiCoreRootReference, reason: String) {
    switch target {
    case .node(let nodeId):
      let settlementGen = planeBSettlementGeneration
      let intentID = nextCoreIntentID()
      let rootBefore = coreCurrentRootID
      // Optimistic gate: accept HUD for the known target immediately (play-class latency).
      if nodeId != UInt32.max {
        coreCurrentRootID = nodeId
      }
      guard let core = coreBackendService else {
        finishPlaneBNavGate(success: false)
        return
      }
      let posted = core.postNavSwitchRootSync(nodeId: nodeId, uiIntentId: intentID)
      Task { [weak self] in
        guard let self else { return }
        if !posted {
          await MainActor.run {
            guard settlementGen == self.planeBSettlementGeneration else { return }
            self.coreCurrentRootID = rootBefore
            self.finishPlaneBNavGate(success: false)
          }
          return
        }
        await self.awaitPlaneBRootSettlement(
          core: core,
          rootBefore: rootBefore,
          expectedRoot: nodeId,
          settlementGeneration: settlementGen
        )
      }
    default:
      // Lineage / intent: FIFO resolve, settle via HUD only (no structure JSON on critical path).
      postNavJumpFIFO(.jumpToNode(target, expectedBackendEpoch: 0), reason: reason)
    }
  }

  /// FIFO jump/step when Plane B node id is unknown. Settles on lock-free HUD only.
  private func postNavJumpFIFO(_ request: QixiCoreRequest, reason: String) {
    let settlementGen = planeBSettlementGeneration
    let rootBefore = coreCurrentRootID
    submitCoreMutation(request, reason: reason) { [weak self] success in
      guard let self, settlementGen == self.planeBSettlementGeneration else { return }
      guard success, let core = self.coreBackendService else {
        self.finishPlaneBNavGate(success: false)
        return
      }
      // Do NOT await latestCoreSnapshot here — that JSON path was the multi-second freeze.
      Task { [weak self] in
        guard let self else { return }
        await self.awaitPlaneBRootSettlement(
          core: core,
          rootBefore: rootBefore,
          expectedRoot: nil,
          settlementGeneration: settlementGen
        )
      }
    }
  }

  /// Wait ≤100 ms for the published analyze root to leave `rootBefore` (or match expected).
  private func awaitPlaneBRootSettlement(
    core: any QixiCoreBackendService,
    rootBefore: UInt32,
    expectedRoot: UInt32?,
    settlementGeneration: UInt64
  ) async {
    let deadline = ContinuousClock.now + .milliseconds(100)
    var lastYield = ContinuousClock.now
    while ContinuousClock.now < deadline {
      if let payload = core.tryLoadAnalyzeDisplaySync(),
         payload.root != UInt32.max {
        let matchedExpected = expectedRoot.map { payload.root == $0 } ?? false
        let leftPrevious = payload.root != rootBefore
        if matchedExpected || leftPrevious {
          await MainActor.run {
            guard settlementGeneration == self.planeBSettlementGeneration else { return }
            self.coreCurrentRootID = payload.root
            self.finishPlaneBNavGate(success: true)
            self.paintAnalyzeHUD(
              payload,
              engine: self.selectedEngine,
              preservedEngineError: self.lastEngineError
            )
          }
          return
        }
      }
      if ContinuousClock.now - lastYield >= .milliseconds(1) {
        lastYield = ContinuousClock.now
        await Task.yield()
      }
    }
    // Timeout: still open the gate. Optimistic coreCurrentRootID (when set) keeps HUD live.
    await MainActor.run {
      guard settlementGeneration == self.planeBSettlementGeneration else { return }
      if let expectedRoot, expectedRoot != UInt32.max {
        self.coreCurrentRootID = expectedRoot
      }
      self.finishPlaneBNavGate(success: true)
      self.forceApplyLatestAnalyzeDisplay(
        engine: self.selectedEngine,
        preservedEngineError: self.lastEngineError
      )
    }
  }

  /// Gate HUD/structure while Plane B nav is in flight.
  /// Root scrub/jump **supersedes** any prior in-flight switch (latest-wins).
  private func beginPlaneBNavGate(usingCore: Bool, clearDisplay: Bool = true) {
    guard usingCore else {
      planeBNavInFlight = 0
      return
    }
    // Abandon prior settlement tasks; only the newest jump matters.
    if planeBNavInFlight > 0 {
      planeBSettlementGeneration &+= 1
    }
    planeBNavInFlight = 1
    if clearDisplay {
      analyzeDisplay.clear()
      refreshNextMoveDecoration()
    }
  }

  private func finishPlaneBNavGate(success: Bool) {
    planeBNavInFlight = max(0, planeBNavInFlight - 1)
    if planeBNavInFlight == 0 {
      // Always allow HUD for the settled (or optimistic) root after gate opens.
      lastAppliedAnalyzeCoreRoot = coreCurrentRootID
    }
    _ = success
  }

  private func shouldAcceptAnalyzeCoreRoot(_ root: UInt32) -> Bool {
    // While any Plane B nav is outstanding, ignore all HUD/structure (avoids intermediate B
    // while UI already at C, and prevents old-root metrics poisoning the new cache key).
    // Exception: accept the optimistically-selected target root so post-jump paint is instant.
    if planeBNavInFlight != 0 {
      if root == UInt32.max { return false }
      return root == coreCurrentRootID && coreCurrentRootID != UInt32.max
    }
    if root == UInt32.max { return false }
    // Accept when root matches settled id. Also accept while coreCurrentRootID is still
    // the invalid sentinel (never successfully settled) so engine load is not stuck silent.
    if coreCurrentRootID == UInt32.max { return true }
    return root == coreCurrentRootID
  }

  private func noteAcceptedAnalyzeCoreRoot(_ root: UInt32) {
    lastAppliedAnalyzeCoreRoot = root
  }

  /// Undo a failed optimistic play/pass so UI matches core again.
  private func rollbackOptimisticPlay(
    optimisticNodeID: String,
    restoreNodeID: String,
    restoreMainLine: [BoardMove],
    restorePly: Int
  ) {
    variation.coreRootReferenceByNodeID.removeValue(forKey: optimisticNodeID)
    if let parentID = variation.records[optimisticNodeID]?.parentID {
      variation.childIDsByParent[parentID]?.removeAll { $0 == optimisticNodeID }
    }
    variation.records.removeValue(forKey: optimisticNodeID)
    variation.childIDsByParent.removeValue(forKey: optimisticNodeID)
    variation.reassignLanes()
    mainLine = restoreMainLine
    currentPly = min(max(0, restorePly), mainLine.count)
    variation.currentNodeID = restoreNodeID
    variation.currentPathNodeIDs = variation.primaryPathNodeIDs(from: restoreNodeID)
    invalidateVariationTreeCache()
    clearVisibleAnalysisAndRefreshAnchor()
    if selectedEngine != .none {
      _ = restoreCachedAnalysisForCurrentPosition()
    }
    lastEngineError = lastEngineError ?? "navigation rejected by engine"
  }

  func candidateDelta(_ candidate: CandidateMove) -> Double {
    let visited = candidates.filter { $0.visits > 0 }
    guard !visited.isEmpty else { return 0 }
    return CandidatePalette.qualityDeltaPercent(
      winrate: candidate.winrate,
      scoreMean: candidate.scoreMean,
      peerWinrates: visited.map(\.winrate),
      peerScores: visited.map(\.scoreMean),
      positionSideToMoveWinrate: analyzeDisplay.rootWinrate
    ) ?? 0
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
    memoizedCurrentAnalysisCacheKey = nil
    lastNextMoveDecorationKey = nil
    invalidateChartPointsCache()
    refreshNextMoveDecoration()
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
    let sampledNextMovePointID = Self.sampledNextMovePointID(
      nextMoveOverlay: nextMoveOverlay,
      candidates: candidates
    )
    let rootSTM = analyzeDisplay.rootWinrate
    cachedVisibleCandidates = Self.visibleCandidates(
      from: candidates,
      bestWinrate: best,
      forcedPointID: sampledNextMovePointID,
      positionSideToMoveWinrate: rootSTM
    )
    cachedVisibleCandidateOverlays = Self.visibleCandidateOverlays(
      from: cachedVisibleCandidates,
      bestWinrate: best,
      nextMoveOverlay: nextMoveOverlay,
      positionSideToMoveWinrate: rootSTM
    )
    refreshNextMoveDecoration(using: nextMoveOverlay)
  }

  /// Layer next-move outline / thin edge-ring onto the lock-free analyze display.
  /// - Parameter includeChildCache: When false (HUD hot path), skip O(history) child
  ///   position-key construction; HUD sampling still marks rings.
  private func refreshNextMoveDecoration(
    using provided: QixiNextMoveOverlayContext? = nil,
    includeChildCache: Bool = true
  ) {
    let nextMoveOverlay = provided ?? nextMoveOverlayContext(includeChildCache: includeChildCache)
    guard let nextMoveOverlay else {
      if lastNextMoveDecorationKey != nil {
        lastNextMoveDecorationKey = nil
      }
      if nextMoveShowsCaptureOutlines {
        nextMoveShowsCaptureOutlines = false
      }
      analyzeDisplay.setNextMoveDecoration(nil)
      return
    }

    let currentRootCandidate = candidates.first {
      $0.id == nextMoveOverlay.pointID && $0.visits > 0
    }
    let hudSampled = analyzeDisplay.sampledHUDCandidate(atPointID: nextMoveOverlay.pointID)
    let isSampled = nextMoveOverlay.isSampled || hudSampled != nil
    let forcedVisits: Int
    let forcedWinrate: Double
    if let currentRootCandidate {
      forcedVisits = currentRootCandidate.visits
      forcedWinrate = currentRootCandidate.winrate
    } else if let hudSampled {
      forcedVisits = hudSampled.visits
      forcedWinrate = hudSampled.winrate
    } else if let childRootCache = nextMoveOverlay.childRootCache, childRootCache.visits > 0 {
      forcedVisits = childRootCache.visits
      forcedWinrate = 1.0 - childRootCache.winrate
    } else {
      forcedVisits = 0
      forcedWinrate = 0
    }
    let decorationKey = NextMoveDecorationKey(
      ply: currentPly,
      pointID: nextMoveOverlay.pointID,
      color: nextMoveOverlay.color,
      currentRootVisits: nextMoveOverlay.currentRootVisits,
      childRootVisits: nextMoveOverlay.childRootVisits,
      hudSampledVisits: hudSampled?.visits ?? 0,
      isSampled: isSampled,
      forcedVisits: forcedVisits,
      forcedWinrateBits: forcedWinrate.bitPattern
    )
    if decorationKey == lastNextMoveDecorationKey {
      return
    }
    lastNextMoveDecorationKey = decorationKey

    var decoration = QixiNextMoveDecoration(
      x: nextMoveOverlay.x,
      y: nextMoveOverlay.y,
      color: nextMoveOverlay.color,
      isSampled: isSampled
    )
    if isSampled {
      if let currentRootCandidate {
        decoration.forcedRankText = String(currentRootCandidate.rank)
        decoration.forcedWinrate = currentRootCandidate.winrate
        decoration.forcedVisits = currentRootCandidate.visits
        decoration.forcedScoreMean = currentRootCandidate.scoreMean
        let visited = candidates.filter { $0.visits > 0 }
        if !visited.isEmpty {
          let delta = CandidatePalette.qualityDeltaPercent(
            winrate: currentRootCandidate.winrate,
            scoreMean: currentRootCandidate.scoreMean,
            peerWinrates: visited.map(\.winrate),
            peerScores: visited.map(\.scoreMean),
            positionSideToMoveWinrate: analyzeDisplay.rootWinrate
          ) ?? 0.0
          decoration.forcedColorComponents = CandidatePalette.components(deltaPercent: delta)
        }
      } else if let hudSampled {
        // HUD sampled the move but it fell outside the normal winrate window.
        decoration.forcedRankText = String(hudSampled.rank)
        decoration.forcedWinrate = hudSampled.winrate
        decoration.forcedVisits = hudSampled.visits
        decoration.forcedScoreMean = hudSampled.scoreMean
        decoration.forcedColorComponents = hudSampled.colorComponents
      } else if let childRootCache = nextMoveOverlay.childRootCache, childRootCache.visits > 0 {
        // Child-root cache is side-to-move *after* the next move (opponent). Invert to current STM.
        decoration.forcedRankText = ">"
        decoration.forcedWinrate = 1.0 - childRootCache.winrate
        decoration.forcedVisits = childRootCache.visits
        decoration.forcedScoreMean = -childRootCache.scoreMean
        decoration.forcedColorComponents = CandidatePalette.unknownAnalysisComponents
      }
    }
    analyzeDisplay.setNextMoveDecoration(decoration)

    // Capture outlines only when the next move is still an unanalyzed faint outline
    // (merge may promote a HUD-resident point to a ringed analysis disk).
    let usesOutlineMarker = analyzeDisplay.overlays.contains {
      $0.id == nextMoveOverlay.pointID && $0.usesStoneSizedContinuationMarker
    }
    let showCaptureOutlines = usesOutlineMarker && !nextMoveCapturedBoardPointIDs.isEmpty
    if nextMoveShowsCaptureOutlines != showCaptureOutlines {
      nextMoveShowsCaptureOutlines = showCaptureOutlines
    }
  }

  private func nextMoveOverlayContext(includeChildCache: Bool = true) -> QixiNextMoveOverlayContext? {
    guard currentPly >= 0, currentPly < mainLine.count else { return nil }
    let move = mainLine[currentPly]
    guard !move.isPass, let x = move.x, let y = move.y else { return nil }
    let pointID = y * 19 + x
    let currentRootVisits = max(0, candidates.first(where: { $0.id == pointID })?.visits ?? 0)
    let childRootCache: QixiCachedAnalysis?
    if !includeChildCache || selectedEngine == .none {
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
      currentRootVisits: currentRootVisits,
      childRootVisits: max(0, childRootCache?.visits ?? 0),
      childRootCache: childRootCache
    )
  }

  private static func sampledNextMovePointID(
    nextMoveOverlay: QixiNextMoveOverlayContext?,
    candidates: [CandidateMove]
  ) -> Int? {
    guard let nextMoveOverlay, nextMoveOverlay.isSampled else { return nil }
    // Prefer a current-root candidate so forced display keeps live metrics.
    if candidates.contains(where: { $0.id == nextMoveOverlay.pointID && $0.visits > 0 }) {
      return nextMoveOverlay.pointID
    }
    // Child analysis alone still forces display of the known next move.
    if nextMoveOverlay.childRootVisits > 0 {
      return nextMoveOverlay.pointID
    }
    return nil
  }

  private static func visibleCandidates(
    from candidates: [CandidateMove],
    bestWinrate: Double?,
    forcedPointID: Int? = nil,
    positionSideToMoveWinrate: Double? = nil
  ) -> [CandidateMove] {
    let items = candidates.enumerated().map { index, c in
      CandidateQualityLayout.Item(
        x: c.x,
        y: c.y,
        visits: c.visits,
        winrate: c.winrate,
        scoreMean: c.scoreMean,
        sourceIndex: c.rank > 0 ? c.rank - 1 : index
      )
    }
    let (_, ranked) = CandidateQualityLayout.layout(
      items,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    )
    var visible = ranked.map { item in
      CandidateMove(
        x: item.x,
        y: item.y,
        rank: item.rank,
        winrate: item.winrate,
        visits: item.visits,
        scoreMean: item.scoreMean
      )
    }
    // Fallback when layout empty but bestWinrate path had data (no visits).
    if visible.isEmpty, let bestWinrate {
      let peerWR = candidates.map(\.winrate)
      let peerSC = candidates.map(\.scoreMean)
      let mode = CandidatePalette.qualityMode(
        winrates: peerWR,
        scores: peerSC,
        positionSideToMoveWinrate: positionSideToMoveWinrate
      )
      visible = candidates
        .sorted { $0.rank < $1.rank }
        .prefix(10)
        .filter { candidate in
          if let mode,
             let k = CandidatePalette.qualityDeltaPercent(
              winrate: candidate.winrate,
              scoreMean: candidate.scoreMean,
              peerWinrates: peerWR,
              peerScores: peerSC,
              positionSideToMoveWinrate: positionSideToMoveWinrate
             ) {
            return CandidatePalette.isInDisplayWindow(paletteDeltaK: k, mode: mode)
          }
          // Last-resort winrate window (same as normal mode).
          return (candidate.winrate - bestWinrate) * 100.0 > -CandidatePalette.winrateDisplayWindowPercent
        }
        .map { $0 }
    }
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
    nextMoveOverlay: QixiNextMoveOverlayContext? = nil,
    positionSideToMoveWinrate: Double? = nil
  ) -> [VisibleCandidateOverlay] {
    var overlays: [VisibleCandidateOverlay] = []
    overlays.reserveCapacity(visibleCandidates.count + (nextMoveOverlay == nil ? 0 : 1))
    let items = visibleCandidates.enumerated().map { index, c in
      CandidateQualityLayout.Item(
        x: c.x,
        y: c.y,
        visits: c.visits,
        winrate: c.winrate,
        scoreMean: c.scoreMean,
        sourceIndex: c.rank > 0 ? c.rank - 1 : index
      )
    }
    let (mode, ranked) = CandidateQualityLayout.layout(
      items,
      positionSideToMoveWinrate: positionSideToMoveWinrate
    )
    if let mode, !ranked.isEmpty {
      for item in ranked {
        overlays.append(
          VisibleCandidateOverlay(
            x: item.x,
            y: item.y,
            rankText: String(item.rank),
            winrateText: NumberText.winrate(item.winrate),
            visitsText: String(item.visits),
            scoreText: NumberText.score(item.scoreMean),
            colorComponents: item.colorComponents
          )
        )
      }
      _ = mode
    } else if let bestWinrate {
      // Fallback when layout returned empty: still prefer score-loss when extreme-low.
      let peerWR = visibleCandidates.map(\.winrate)
      let peerSC = visibleCandidates.map(\.scoreMean)
      for candidate in visibleCandidates {
        let delta = CandidatePalette.qualityDeltaPercent(
          winrate: candidate.winrate,
          scoreMean: candidate.scoreMean,
          peerWinrates: peerWR,
          peerScores: peerSC,
          positionSideToMoveWinrate: positionSideToMoveWinrate
        ) ?? ((candidate.winrate - bestWinrate) * 100.0)
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
      if !nextMoveOverlay.isSampled {
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
      } else if let index = overlays.firstIndex(where: { $0.id == nextMoveOverlay.pointID }) {
        // Already visible as a current-root candidate; mark with a thin stone-color ring.
        overlays[index].continuationRingColor = nextMoveOverlay.color
      } else if let childRootCache = nextMoveOverlay.childRootCache, childRootCache.visits > 0 {
        // Sampled via child analysis but outside the normal display set — force show.
        overlays.append(
          VisibleCandidateOverlay(
            x: nextMoveOverlay.x,
            y: nextMoveOverlay.y,
            rankText: ">",
            winrateText: NumberText.winrate(1.0 - childRootCache.winrate),
            visitsText: String(childRootCache.visits),
            scoreText: NumberText.score(-childRootCache.scoreMean),
            colorComponents: CandidatePalette.unknownAnalysisComponents,
            continuationRingColor: nextMoveOverlay.color
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
      // Prefer the core backend message captured by recoverFromCoreMutationFailure.
      let detail = lastEngineError?.isEmpty == false ? lastEngineError : String(describing: error)
      throw QixiCoreBarrierError(operation: reason, backendMessage: detail)
    }
  }

  private func submitCoreEngineSelectionAndWait(
    _ engine: AnalysisEngine,
    reason: String
  ) async throws {
    do {
      try await coreMutationQueue.selectEngineAndWait(engine, reason: reason, host: self)
    } catch {
      let detail = lastEngineError?.isEmpty == false ? lastEngineError : String(describing: error)
      throw QixiCoreBarrierError(operation: reason, backendMessage: detail)
    }
  }

  func noteCoreMutationCommittedIntent(
    uiIntentID: UInt64,
    optimisticVariationNodeID: String,
    result: QixiCoreBackendResult
  ) {
    // Always prefer core node id for O(1) Plane B switchRoot on later jumps.
    if result.currentRoot != UInt32.max {
      variation.coreRootReferenceByNodeID[optimisticVariationNodeID] = .node(result.currentRoot)
    } else if let snap = result.snapshot {
      variation.coreRootReferenceByNodeID[optimisticVariationNodeID] = .lineage(snap.rootLineageHash)
    }
    _ = uiIntentID
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

  // MARK: - QixiPersistenceHost

  var hasCoreBackend: Bool { coreBackendService != nil }

  func notePersistenceError(_ message: String?) {
    lastSaveError = message
  }

  func noteSyncResult(_ result: QixiSyncResult) {
    // Transport is opportunistic: iCloud when the container exists, else local.
    // No user authorization preference to flip — only reflect availability.
    let usedICloud = result.provider == .iCloud
    if usedICloud != iCloudSyncEnabled {
      setICloudSyncEnabled(usedICloud)
    }
    // Re-list after MCTS/SGF mirror so the UI reflects everything just written.
    let visibleNames = QixiSyncStore.listVisibleDocumentNames()
    let fallbackError: String?
    if usedICloud, visibleNames.isEmpty {
      fallbackError =
        "Wrote to iCloud container but Documents is still empty. " +
        "Check Settings → [Apple ID] → iCloud → iCloud Drive is on for 棋析."
    } else {
      fallbackError = nil
    }
    let fileList = visibleNames.isEmpty
      ? "(no files listed yet)"
      : visibleNames.joined(separator: ", ")
    let detail: String
    if usedICloud {
      detail =
        "Look in Files → iCloud Drive → Qixi (not Documents/Qixi). " +
        "On device now: \(fileList)"
    } else {
      detail = "Local fallback only: \(fileList)"
    }
    syncStatus = QixiSyncStatus(
      provider: result.provider,
      lastSyncAt: Date(),
      lastError: fallbackError,
      lastDetail: detail
    )
  }

  func noteSyncMirrorFailure(_ message: String) {
    syncStatus = QixiSyncStatus(
      provider: syncStatus.provider,
      lastSyncAt: syncStatus.lastSyncAt,
      lastError: message,
      lastDetail: syncStatus.lastDetail
    )
  }

  func applyImportedAppSnapshot(_ snapshot: QixiAppSnapshot) {
    apply(snapshot: snapshot)
    // Resume is owned by the caller (SyncCoordinator calls resumeAnalysisAfterImportedSnapshot).
    // Do not double-enqueue the main line into core here.
  }

  func submitCoreAutosaveTick(reason: String) {
    // Product: core periodic autosave disabled (OOM hard unload still checkpoints itself).
    _ = reason
  }

  func syncNow() {
    syncCoordinator.syncNow()
  }

  func cancelPendingPersistenceSave() {
    persistence.cancelPendingSave()
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

  func completeOnboarding() {
    onboardingCompleted = true
    UserDefaults.standard.set(true, forKey: QixiPreferences.onboardingCompletedKey)
    // Archives/mirrors use iCloud automatically when the container is available —
    // no onboarding opt-in and no authorization prompt.
    setICloudSyncEnabled(QixiSyncStore.isICloudContainerAvailable)
    persistence.saveNow(reason: "onboardingCompleted")
  }

  func openUtilitySheet(_ sheet: QixiUtilitySheet) {
    // Archive and Open must open even while analysis is running so pickers work;
    // the open/archive actions themselves re-check the barrier before mutating.
    // Camera still waits out blocking backend work.
    if sheet == .camera, isBackendInteractionBlocked { return }
    if sheet == .importGame, sessionHasUnsavedChanges {
      pendingUnsavedDecision = QixiUnsavedChangesDecision(kind: .openSheet)
      return
    }
    utilitySheet = sheet
  }

  func newGame() {
    guard !isBackendInteractionBlocked else { return }
    if sessionHasUnsavedChanges {
      pendingUnsavedDecision = QixiUnsavedChangesDecision(kind: .newGame)
      return
    }
    performNewGame()
  }

  private func performNewGame() {
    guard !isBackendInteractionBlocked else { return }
    let transitionToken = beginBackendTransition(.exportingState)
    analysisTask?.cancel()
    analysisRefreshTask?.cancel()
    let snapshotToArchive = currentSnapshot(reason: "newGameMCTSStateArchive")
    Task { [weak self] in
      guard let self else { return }
      defer { self.finishBackendTransition(transitionToken) }
      await archiveCurrentPositionSeparately(
        snapshotToArchive,
        reason: "newGameMCTSStateArchive"
      )
      resetForNewGame()
      clearSessionDirty()
    }
  }

  func markSessionDirty() {
    if !sessionHasUnsavedChanges {
      sessionHasUnsavedChanges = true
    }
  }

  func clearSessionDirty() {
    sessionHasUnsavedChanges = false
  }

  /// Resolve save / discard / cancel for pending navigation.
  func resolveUnsavedDecision(_ choice: QixiUnsavedChoice) {
    guard let pending = pendingUnsavedDecision else { return }
    pendingUnsavedDecision = nil
    switch choice {
    case .cancel:
      return
    case .discard:
      clearSessionDirty()
      continueAfterUnsavedResolved(pending.kind, didSave: false)
    case .save:
      Task { @MainActor in
        do {
          // Existing document → replace; untitled → create with default/suggested name.
          try await saveArchiveAndSync(fileName: defaultArchiveFileName())
          clearSessionDirty()
          continueAfterUnsavedResolved(pending.kind, didSave: true)
        } catch {
          lastSaveError = String(describing: error)
        }
      }
    }
  }

  private func continueAfterUnsavedResolved(_ kind: QixiUnsavedKind, didSave: Bool) {
    switch kind {
    case .newGame:
      performNewGame()
    case .openSheet:
      utilitySheet = .importGame
    case .openArchive(let item):
      Task { @MainActor in
        try? await performOpenArchiveListItem(item)
      }
    case .appBackground:
      break
    }
  }

  /// Best-effort archive when leaving the app with unsaved work (iOS cannot cancel quit).
  func handleAppWillBackground() {
    guard sessionHasUnsavedChanges else { return }
    let snapshot = currentSnapshot(reason: "appBackgroundArchive")
    Task { @MainActor in
      await archiveCurrentPositionSeparately(snapshot, reason: "appBackgroundArchive")
      clearSessionDirty()
    }
  }

  private func resetForNewGame() {
    invalidateActiveAnalysisForPositionChange()
    analysisTask?.cancel()
    analysisRefreshTask?.cancel()
    analysisGeneration += 1
    planeBSettlementGeneration &+= 1
    planeBNavInFlight = 0
    lastAppliedAnalyzeCoreRoot = nil
    mainLine = []
    currentPly = 0
    explicitRootSideToMove = .black
    // Full tree wipe: records, lanes, core refs, quality deltas.
    variation = QixiVariationModel()
    resetVariationTree(from: [], currentPly: 0)
    variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
    invalidateVariationTreeCache()
    clearRecognizedSetup()
    clearVisibleAnalysisAndRefreshAnchor()
    analysisCache.clear()
    clearCurrentArchiveDocument()
    coreCurrentRootID = 0
    updateBoardMoveCache()
    updateCandidateCaches()
    persistence.saveNow(reason: "newGame")
    if coreBackendService != nil {
      // Must restart HUD polling after cancel above — selectedEngine stays e.g. b18, so
      // re-tapping the same engine is a no-op and analysis would stay dead forever.
      submitCoreMutation(
        .newGame(komi: komi, nextPla: .black, expectedBackendEpoch: 0),
        reason: "coreNewGame"
      ) { [weak self] _ in
        guard let self else { return }
        self.coreCurrentRootID = 0
        self.lastAppliedAnalyzeCoreRoot = nil
        self.requestAnalysisIfNeeded(assumesEngineAlreadyLoaded: true)
      }
      return
    }
    requestAnalysisIfNeeded()
  }

  // MARK: - Open (打开)

  func openSGF(text: String) async throws {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "open SGF", backendMessage: "another backend transition is active")
    }
    // Best-effort WPS save of the previous document when dirty.
    if sessionHasUnsavedChanges {
      let prior = currentSnapshot(reason: "openSGFArchivePrior")
      await archiveCurrentPositionSeparately(prior, reason: "openSGFArchivePrior")
    }
    try importSGFReplacingCurrent(text: text)
    clearSessionDirty()
  }

  func openMCTSStatePackage(from packageURL: URL, originURL: URL? = nil) async throws {
    // Best-effort WPS save of the previous document when dirty (replace or create).
    if !isBackendInteractionBlocked, sessionHasUnsavedChanges {
      let prior = currentSnapshot(reason: "openMCTSArchivePrior")
      await archiveCurrentPositionSeparately(prior, reason: "openMCTSArchivePrior")
    }
    for _ in 0..<240 {
      if !isBackendInteractionBlocked { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(
        operation: "open search state",
        backendMessage: "backend still busy after auto-archive; try again in a moment"
      )
    }
    // Resolve package root in case the picker handed us an inner file URL.
    let resolved = QixiImportedFileAccess.resolveMCTSPackageRootIfNeeded(packageURL)
    try await importMCTSStatePackage(from: resolved)
    // Opened file becomes the current document; later Save simply replaces it.
    if let originURL {
      bindCurrentArchiveDocument(packageURL: originURL)
    } else {
      clearCurrentArchiveDocument()
    }
    clearSessionDirty()
  }

  // MARK: - Open list / Archive / Export

  func listOpenableArchivePackages() -> [QixiSyncStore.ArchiveListItem] {
    // Always include iCloud archives when the ubiquity container is available.
    QixiSyncStore.listArchivePackages()
  }

  func openArchiveListItem(_ item: QixiSyncStore.ArchiveListItem) async throws {
    if sessionHasUnsavedChanges {
      pendingUnsavedDecision = QixiUnsavedChangesDecision(kind: .openArchive(item))
      return
    }
    try await performOpenArchiveListItem(item)
  }

  private func performOpenArchiveListItem(_ item: QixiSyncStore.ArchiveListItem) async throws {
    try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
    var localCopy: URL?
    defer { QixiImportedFileAccess.removeTemporaryCopy(localCopy) }
    let imported = try QixiImportedFileAccess.makeTemporaryLocalCopy(from: item.url)
    localCopy = imported
    try await openMCTSStatePackage(from: imported, originURL: item.url)
    clearSessionDirty()
  }

  /// Whether this session already has a bound archive file (Save = replace).
  var hasExistingArchiveDocument: Bool {
    if let url = currentArchivePackageURL, FileManager.default.fileExists(atPath: url.path) {
      return true
    }
    return currentArchiveBaseName != nil && !(currentArchiveBaseName ?? "").isEmpty
  }

  /// Display name of the bound document, if any.
  var currentArchiveDisplayName: String? {
    if let base = currentArchiveBaseName, !base.isEmpty { return base }
    if let url = currentArchivePackageURL {
      return QixiSyncStore.displayNameWithoutPackageExtension(url.lastPathComponent)
    }
    return nil
  }

  func saveArchiveAndSync(fileName: String) async throws {
    persistence.cancelPendingSave()
    let snapshot = currentSnapshot(reason: "archiveAndSync")
    persistence.saveNow(reason: "archiveAndSync")
    try await saveArchive(
      snapshot: snapshot,
      preferredFileName: fileName,
      reason: "archiveAndSync"
    )
    lastSaveError = nil
    clearSessionDirty()
  }

  /// WPS save:
  /// - existing document → replace package + companion `.sgf` in place
  /// - new/untitled → create under the user-chosen (or suggested) basename
  private func saveArchive(
    snapshot: QixiAppSnapshot,
    preferredFileName: String,
    reason: String
  ) async throws {
    let sgfText = QixiSGFParser.exportGame(
      moves: snapshot.mainLine,
      setupStones: snapshot.recognizedSetupStones ?? [],
      komi: snapshot.komi,
      nextPlayer: snapshot.nextPlayer
        ?? QixiBoardPosition.nextPlayer(
          after: snapshot.mainLine,
          rootToMove: snapshot.mainLine.first?.color ?? .black
        )
    )

    if let existingURL = currentArchivePackageURL,
       FileManager.default.fileExists(atPath: existingURL.path) {
      let baseName = currentArchiveBaseName
        ?? QixiSyncStore.displayNameWithoutPackageExtension(existingURL.lastPathComponent)
      let packageURL = try await makeMCTSStatePackage(
        snapshot: snapshot,
        reason: reason,
        baseName: baseName,
        includeGameSGF: true,
        includeThumbnail: true
      )
      defer { try? FileManager.default.removeItem(at: packageURL) }
      let replaced = try QixiSyncStore.replaceExistingArchive(
        packageDestinationURL: existingURL,
        packageSourceURL: packageURL,
        sgfText: sgfText,
        baseName: baseName
      )
      currentArchiveBaseName = QixiSyncStore.sanitizeFileBaseName(baseName)
      currentArchivePackageURL = replaced.packageURL
    } else {
      // First save / untitled: user-chosen name (sheet) or suggested default.
      let baseName = QixiSyncStore.sanitizeFileBaseName(
        preferredFileName.isEmpty ? defaultArchiveFileName() : preferredFileName
      )
      let packageURL = try await makeMCTSStatePackage(
        snapshot: snapshot,
        reason: reason,
        baseName: baseName,
        includeGameSGF: true,
        includeThumbnail: true
      )
      defer { try? FileManager.default.removeItem(at: packageURL) }
      let written = try QixiSyncStore.writeArchiveAndSync(
        sgfText: sgfText,
        packageSourceURL: packageURL,
        preferredBaseName: baseName
      )
      currentArchiveBaseName = baseName
      // Prefer the cloud copy as the live document when both exist.
      currentArchivePackageURL = written.cloudPackage ?? written.localPackage
    }

    if QixiSyncStore.isICloudContainerAvailable {
      setICloudSyncEnabled(true)
      _ = try? QixiSyncStore.replaceVisibleCurrentGameSGF(with: sgfText)
    }
  }

  func prepareExportShareFiles() async throws -> [URL] {
    let baseName = defaultArchiveFileName()
    let sgfURL = try prepareSGFExportFile(baseName: baseName)
    let packageURL = try await prepareArchiveExport(
      options: QixiArchiveExportOptions(
        fileName: baseName,
        includeSGF: true,
        includeSearchState: true
      )
    )
    return [sgfURL, packageURL]
  }

  // MARK: - Archive (存档)

  /// Suggested name for a *new* document; bound documents reuse their own name.
  func defaultArchiveFileName() -> String {
    if let existing = currentArchiveDisplayName, !existing.isEmpty {
      return existing
    }
    return QixiSyncStore.defaultArchiveBaseName()
  }

  var hasArchivableGameRecord: Bool {
    !mainLine.isEmpty || !(recognizedSetupStones ?? []).isEmpty
  }

  /// Whether the optional search-state package can be included (position and/or analysis).
  /// Plain .sgf remains independently selectable; search is opt-in in the archive sheet.
  var hasArchivableSearchState: Bool {
    hasArchivableGameRecord ||
      analysisCache.isEmpty == false ||
      analysisByEngineHasEntries
  }

  private var analysisByEngineHasEntries: Bool {
    currentSnapshot(reason: "archiveProbe").analysisByEngine.values.contains { !$0.isEmpty }
  }

  func boardThumbnailImage(pixelSize: CGFloat) -> UIImage {
    // Board as currently committed (ply on the main line) — matches what the user sees.
    let moves = QixiBoardThumbnailRenderer.movesForThumbnail(
      mainLine: mainLine,
      currentPly: currentPly
    )
    return QixiBoardThumbnailRenderer.render(
      moves: moves,
      setupStones: recognizedSetupStones ?? [],
      pixelSize: pixelSize
    )
  }

  func prepareArchiveExport(options: QixiArchiveExportOptions) async throws -> URL {
    let baseName = QixiSyncStore.sanitizeFileBaseName(options.fileName)
    let includeSGF = options.includeSGF
    let includeSearch = options.includeSearchState
    guard includeSGF || includeSearch else {
      throw QixiCoreBarrierError(
        operation: "archive",
        backendMessage: "select at least one content type"
      )
    }
    // SGF-only: plain .sgf for maximum portability.
    if includeSGF, !includeSearch {
      return try prepareSGFExportFile(baseName: baseName)
    }
    // Search state (± SGF inside package) as independent .qixi-mcts package.
    persistence.cancelPendingSave()
    let snapshot = currentSnapshot(reason: "manualArchiveExport")
    persistence.saveNow(reason: "manualArchiveExport")
    let packageURL = try await makeMCTSStatePackage(
      snapshot: snapshot,
      reason: "manualArchiveExport",
      baseName: baseName,
      includeGameSGF: includeSGF,
      includeThumbnail: true
    )
    lastSaveError = nil
    return packageURL
  }

  func importSGF(text: String) throws {
    try importSGFReplacingCurrent(text: text)
  }

  private func importSGFReplacingCurrent(text: String) throws {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "SGF import", backendMessage: "another backend transition is active")
    }
    let importedGame = try QixiSGFParser.parseValidatedGame(from: text)
    let importedMoves = importedGame.moves
    let importedSetup = Self.normalizedSetupStones(importedGame.setupStones)
    invalidateActiveAnalysisForPositionChange()
    mainLine = importedMoves
    currentPly = importedMoves.count
    resetVariationTree(from: importedMoves, currentPly: currentPly)
    // Drop any previous photographed/imported setup, then apply AB/AW if present.
    clearRecognizedSetup()
    if !importedSetup.isEmpty {
      recognizedSetupStones = importedSetup
      updateBoardMoveCache()
    }
    // KM from SGF is product komi when present and valid.
    if let importedKomi = importedGame.komi, QixiAnalysisLimits.isValidKomi(importedKomi) {
      komi = QixiAnalysisLimits.normalizedKomi(importedKomi)
    }
    explicitRootSideToMove = importedGame.nextPlayer
    clearVisibleAnalysis()
    analysisCache.clear()
    // Plain SGF open has no bound archive package (becomes untitled until Save).
    clearCurrentArchiveDocument()
    refreshLocalChartAnchor()
    persistence.saveNow(reason: "sgfImport")
    if coreBackendService != nil {
      variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
      // Prefer explicit PL; else first move color; else Black.
      let sideToMove = importedGame.nextPlayer
      if !importedSetup.isEmpty {
        // AB/AW must become root setup stones — no synthetic move history.
        submitCoreMutation(
          .applyRecognizedBoard(
            setupStones: importedSetup,
            nextPla: sideToMove,
            expectedBackendEpoch: 0
          ),
          reason: "coreSGFImportSetup"
        )
        submitCoreMutation(.setKomi(komi, expectedBackendEpoch: 0), reason: "coreSGFImportKomi")
      } else {
        submitCoreMutation(
          .newGame(komi: komi, nextPla: sideToMove, expectedBackendEpoch: 0),
          reason: "coreSGFImportReset"
        )
      }
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
    try await prepareArchiveExport(
      options: QixiArchiveExportOptions(
        fileName: defaultArchiveFileName(),
        includeSGF: false,
        includeSearchState: true
      )
    )
  }

  func prepareSGFExportFile() throws -> URL {
    try prepareSGFExportFile(baseName: defaultArchiveFileName())
  }

  private func prepareSGFExportFile(baseName: String) throws -> URL {
    let text = currentGameSGFText()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(QixiSyncStore.sanitizeFileBaseName(baseName))
      .appendingPathExtension("sgf")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    guard let data = text.data(using: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    try data.write(to: url, options: [.atomic])
    return url
  }

  private func currentGameSGFText() -> String {
    QixiSGFParser.exportGame(
      moves: mainLine,
      setupStones: recognizedSetupStones ?? [],
      komi: komi,
      nextPlayer: rootSideToMove
    )
  }

  private func mirrorVisibleMCTSStatePackageToICloudIfNeeded(
    result: QixiSyncResult,
    reason: String
  ) async throws {
    guard result.provider == .iCloud else { return }
    let snapshot = currentSnapshot(reason: reason)
    _ = try await mirrorVisibleMCTSStatePackage(snapshot: snapshot, reason: reason)
    // Also publish a plain .sgf so Files / other devices can open the game without
    // understanding the Qixi package format.
    _ = try QixiSyncStore.replaceVisibleCurrentGameSGF(with: currentGameSGFText())
  }

  /// Best-effort WPS save before New / Open / background: replace if bound, else create once.
  private func archiveCurrentPositionSeparately(
    _ snapshot: QixiAppSnapshot,
    reason: String
  ) async {
    let hasGame =
      !snapshot.mainLine.isEmpty || !(snapshot.recognizedSetupStones ?? []).isEmpty
    let hasSearch =
      !snapshot.analysisByEngine.values.allSatisfy(\.isEmpty) ||
      shouldArchiveMCTSStateBeforeReset(snapshot)
    guard hasGame || hasSearch else { return }

    do {
      try await saveArchive(
        snapshot: snapshot,
        preferredFileName: defaultArchiveFileName(),
        reason: reason
      )
      lastSaveError = nil
    } catch {
      lastSaveError = "archive:\(error)"
    }
  }

  private func bindCurrentArchiveDocument(packageURL: URL) {
    let resolved = QixiImportedFileAccess.resolveMCTSPackageRootIfNeeded(packageURL)
    currentArchivePackageURL = resolved.standardizedFileURL
    currentArchiveBaseName = QixiSyncStore.displayNameWithoutPackageExtension(
      resolved.lastPathComponent
    )
  }

  private func clearCurrentArchiveDocument() {
    currentArchiveBaseName = nil
    currentArchivePackageURL = nil
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
    // Manual iCloud sync still updates the "latest" package pointer for convenience,
    // but New/Open always use independent Archives/ files instead.
    let packageURL = try await makeMCTSStatePackage(
      snapshot: snapshot,
      reason: reason,
      baseName: nil,
      includeGameSGF: true,
      includeThumbnail: true
    )
    defer {
      try? FileManager.default.removeItem(at: packageURL)
    }
    let destination = try QixiSyncStore.replaceVisibleMCTSStatePackage(with: packageURL)
    QixiBoardThumbnailRenderer.applyStoredPackageIcon(in: destination)
    return destination
  }

  private func makeMCTSStatePackage(
    snapshot: QixiAppSnapshot,
    reason: String,
    baseName: String?,
    includeGameSGF: Bool,
    includeThumbnail: Bool
  ) async throws -> URL {
    let transitionToken = beginBackendTransition(.exportingState)
    startIoProgressPolling(for: transitionToken)
    defer { finishBackendTransition(transitionToken) }
    await Task.yield()
    var packageSnapshot = snapshot
    if coreBackendService != nil {
      await waitForCoreMutationDrain()
      packageSnapshot = currentSnapshot(reason: reason)
    }
    let packageURL = try QixiMCTSStatePackageStore.freshTemporaryPackageURL(baseName: baseName)
    do {
      updateBackendTransitionProgress(transitionToken, phase: "Writing snapshot", fraction: 0.1)
      try QixiMCTSStatePackageStore.writeSnapshot(packageSnapshot, to: packageURL)
      // Regular MCTS core-state backup only — no engine/lifecycle tombstones.
      var includesCoreState = false
      if coreBackendService != nil {
        let coreStateURL = QixiMCTSStatePackageStore.coreStateURL(in: packageURL)
        updateBackendTransitionProgress(transitionToken, phase: "Serializing MCTS store", fraction: 0.25)
        try await submitCoreMutationAndWait(
          .exportAnalysisState(path: coreStateURL.path, expectedBackendEpoch: 0),
          reason: "coreMCTSStateExport"
        )
        includesCoreState = true
      }
      if includeGameSGF {
        try QixiMCTSStatePackageStore.writeGameSGF(currentGameSGFText(), to: packageURL)
      }
      if includeThumbnail {
        let thumbMoves = QixiBoardThumbnailRenderer.movesForThumbnail(
          mainLine: packageSnapshot.mainLine,
          currentPly: packageSnapshot.currentPly
        )
        let png = QixiBoardThumbnailRenderer.pngData(
          moves: thumbMoves,
          setupStones: packageSnapshot.recognizedSetupStones ?? [],
          pixelSize: QixiBoardThumbnailRenderer.packageIconPixelSize
        )
        if let png {
          try QixiMCTSStatePackageStore.writeThumbnailPNG(png, to: packageURL)
          // Help Files / document pickers show this board instead of a generic package icon.
          QixiBoardThumbnailRenderer.applyPackageIcon(fromPNGData: png, to: packageURL)
        }
      }
      try QixiMCTSStatePackageStore.writeManifest(
        snapshot: packageSnapshot,
        includesEngineTombstone: false,
        includesCoreState: includesCoreState,
        to: packageURL
      )
      // Seal so document pickers / Files show the board PNG as the file icon.
      try QixiMCTSStatePackageStore.sealDirectoryPackageAsImageDocument(packageURL)
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
    // Tombstone-based packages are no longer supported — app snapshot + optional core state only.
    if imported.engineTombstoneURL != nil {
      throw QixiStrictJSONError.malformed(
        label: "Qixi MCTS state package",
        message: "engine tombstones are not supported; use a package with regular core MCTS state"
      )
    }
    apply(snapshot: imported.snapshot)
    persistence.saveNow(reason: "mctsStateImport")
    lastSaveError = nil
    resumeAnalysisForImportedSnapshotIfNeeded()
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

  func recognizeBoardImage(
    data: Data,
    nextPlayer: StoneColor = .black
  ) throws -> QixiBoardRecognitionResult {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "board recognition", backendMessage: "another backend transition is active")
    }
    let result = try QixiBoardImageRecognizer.recognizeBoard(from: data)
    applyBoardRecognition(result, nextPlayer: nextPlayer)
    return result
  }

  func recognizeBoardImage(
    url: URL,
    nextPlayer: StoneColor = .black
  ) throws -> QixiBoardRecognitionResult {
    guard !isBackendInteractionBlocked else {
      throw QixiCoreBarrierError(operation: "board recognition", backendMessage: "another backend transition is active")
    }
    let result = try QixiBoardImageRecognizer.recognizeBoard(from: url)
    applyBoardRecognition(result, nextPlayer: nextPlayer)
    return result
  }

  func applyBoardRecognition(_ result: QixiBoardRecognitionResult, nextPlayer: StoneColor = .black) {
    markSessionDirty()
    guard !isBackendInteractionBlocked else { return }
    let stones = Self.normalizedRecognizedStones(result.stones)
    let setupStones = Self.setupStones(from: stones)
    invalidateActiveAnalysisForPositionChange()
    recognizedSetupStones = setupStones
    mainLine = []
    currentPly = 0
    // Photo has no move history — next player is an explicit root PL choice.
    explicitRootSideToMove = nextPlayer
    resetVariationTree(from: mainLine, currentPly: currentPly)
    updateBoardMoveCache()
    // Applied stones are live setup — drop the dashed recognition preview overlay.
    clearBoardRecognitionPreview()
    clearVisibleAnalysisAndRefreshAnchor()
    // Recognition starts a new position — not the previously opened archive file.
    clearCurrentArchiveDocument()
    persistence.saveSoon(reason: "boardRecognitionApplied")
    if coreBackendService != nil {
      variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
      submitCoreMutation(
        .applyRecognizedBoard(
          setupStones: setupStones,
          nextPla: nextPlayer,
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
    // Never poison HUD gating with kInvalidNode (UInt32.max) from "store not resident".
    if result.currentRoot != UInt32.max {
      coreCurrentRootID = result.currentRoot
    }
    if result.ok {
      lastEngineError = nil
      applyHermesStatus(fromCoreEngineState: result.engineState, ok: true)
    } else {
      lastEngineError = result.message
      applyHermesStatus(fromCoreEngineState: result.engineState, ok: false)
      recordRuntimeDiagnostic(event: "coreBackendRequestFailed", success: false, message: result.message)
      return
    }
    if deferSnapshot { return }
    guard let snapshot = result.snapshot else { return }
    applyCoreSnapshot(snapshot, reason: reason)
  }

  /// Map core engineState strings onto the Hermes badge (right-top corner).
  private func applyHermesStatus(fromCoreEngineState engineState: String, ok: Bool) {
    let next: HermesStatus
    if selectedEngine == .none {
      next = .ready
    } else if !ok {
      next = (engineState == "loading" || engineState == "unloading") ? .loading : .offline
    } else {
      switch engineState {
      case "ready":
        next = .ready
      case "loading", "unloading":
        next = .loading
      case "offline":
        next = .offline
      case "none":
        // Selected engine but core reports none → still loading/switching.
        next = .loading
      default:
        next = .loading
      }
    }
    if hermesStatus != next {
      hermesStatus = next
    }
  }

  /// HUD path: Hermes tracks *model load* state, not "has first visit painted".
  ///
  /// Bug (multi-second / 20s perceived switch with few analyzes): after setEngine finished
  /// in ~1s we set `.ready`, then the next HUD frame with rootVisits==0 demoted back to
  /// `.loading` until free search produced visits — making a completed switch look stuck.
  private func syncHermesStatusWithLiveAnalysis(hasLiveMetrics: Bool) {
    guard selectedEngine != .none else {
      if hermesStatus != .ready { hermesStatus = .ready }
      return
    }
    if lastEngineError != nil {
      if hermesStatus != .offline { hermesStatus = .offline }
      return
    }
    // Loading only while the selected model is not the one resident in core.
    if loadedEngine != selectedEngine {
      if hermesStatus != .loading { hermesStatus = .loading }
      return
    }
    // Model is live — stay ready even before the first post-switch visit paints.
    if hermesStatus != .ready { hermesStatus = .ready }
    _ = hasLiveMetrics
  }

  /// Mirror live root metrics into VM chart/cache fields (side-to-move from core).
  /// Must stay cheap: this runs on the 120 Hz HUD path. Chart corner reads `analyzeDisplay`
  /// directly; do not rewrite @Published VM fields or rebuild cache keys every tick.
  ///
  /// Chart polylines are built only from the analysis cache. After the Plane A HUD split,
  /// `candidates` often stays empty until a structure snapshot — blocking the cache write
  /// made the line chart freeze. Always write root winrate/score/visits; merge candidates.
  private func applyLiveEngineMetricsFromHUD(_ payload: QixiAnalyzeDisplayPayload) {
    guard selectedEngine != .none else { return }
    guard payload.rootVisits > 0 || payload.candidateCount > 0 else { return }
    let visits = Int(clamping: payload.rootVisits)
    let now = ContinuousClock.now
    let rootChanged = payload.root != lastHUDCacheRoot
    let visitsChanged = visits != lastHUDCacheVisits
    let timeDue = lastHUDCacheAt.map { now - $0 >= .milliseconds(400) } ?? true
    // Early phase: mirror every visit so chart/corner update with the first samples.
    // Steady phase: keep cache/position-key work ~2.5 Hz or on larger visit jumps.
    let earlyPhase = visits < 64
    let visitJump = earlyPhase
      ? (visits != lastHUDCacheVisits)
      : (visits >= lastHUDCacheVisits + 4 || visits < lastHUDCacheVisits)
    guard rootChanged || (visitsChanged && visitJump) || timeDue else {
      return
    }
    lastHUDCacheVisits = visits
    lastHUDCacheRoot = payload.root
    lastHUDCacheAt = now
    // Single assignment pass — chart corner tracks analyzeDisplay at full HUD rate.
    if currentWinrate != payload.rootWinrate {
      currentWinrate = payload.rootWinrate
    }
    if currentScoreMean != payload.rootScoreMean {
      currentScoreMean = payload.rootScoreMean
    }
    guard let cacheKey = currentAnalysisCacheKey(for: selectedEngine) else { return }
    let existing = analysisCache.entry(engine: selectedEngine, cacheKey: cacheKey)
    // Prefer live VM candidates; else HUD packet; else keep prior cache (never wipe with []).
    var cands = candidates
    if cands.isEmpty {
      cands = Self.candidateMoves(fromAnalyzePayload: payload)
    }
    if cands.isEmpty {
      cands = existing?.candidates ?? []
    }
    let terr: [TerritoryPoint]
    if !territory.isEmpty {
      terr = territory
    } else if payload.hasOwnership {
      terr = Self.territoryPoints(fromOwnership: payload.ownership)
    } else {
      terr = existing?.territory ?? []
    }
    analysisCache.put(
      engine: selectedEngine,
      cacheKey: cacheKey,
      positionKey: cacheKey,
      winrate: payload.rootWinrate,
      scoreMean: payload.rootScoreMean,
      visits: visits,
      candidates: cands,
      territory: terr
    )
    invalidateChartPointsCache()
    // Unanalyzed plays stay white until the new situation has visits — dye them here.
    refreshUnanalyzedMoveQualityDyeFromLiveChild()
  }

  private func applyCoreSnapshot(_ snapshot: QixiCoreSnapshot, reason: String) {
    // Never poison HUD root gating with kInvalidNode.
    if snapshot.root != UInt32.max {
      coreCurrentRootID = snapshot.root
    }
    currentWinrate = snapshot.rootVisits > 0 ? snapshot.rootWinrate : 0.5
    currentScoreMean = snapshot.rootVisits > 0 ? snapshot.rootScoreMean : 0.0
    candidates = Array(
      snapshot.candidates.enumerated().compactMap { offset, candidate -> CandidateMove? in
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
      }.prefix(10)
    )
    if snapshot.hasOwnership {
      territory = snapshot.ownership.enumerated().compactMap { index, value in
        guard abs(value) >= 0.16 else { return nil }
        return TerritoryPoint(x: index % 19, y: index / 19, ownership: value)
      }
    } else {
      // Do not keep the previous root's territory on a root without ownership.
      territory = []
    }
    // Engine switch must stay O(1): rebuilding the variation tree on the main thread
    // while the worker searches is why users first saw analysis at 10k+ visits.
    // Structure catches up via the async snapshotPollStructure path.
    let skipTreeRebuild = reason == "coreEngineSelected" ||
      reason == "coreEngineUnloaded" ||
      snapshot.visibleTree.isEmpty
    if !skipTreeRebuild {
      rebuildVariationTree(from: snapshot)
    }
    if selectedEngine != .none, let cacheKey = currentAnalysisCacheKey(for: selectedEngine) {
      cacheCurrentAnalysis(
        engine: selectedEngine,
        cacheKey: cacheKey,
        positionKey: cacheKey,
        visits: Int(clamping: snapshot.rootVisits)
      )
    }
    if reason != "snapshotPollStructure" || snapshot.rootVisits.isMultiple(of: 64) {
      recordRuntimeDiagnostic(
        event: "coreSnapshotApplied",
        success: true,
        message: "root=\(snapshot.root) visits=\(snapshot.rootVisits) candidates=\(snapshot.candidates.count) reason=\(reason)"
      )
    }
  }

  private func rebuildVariationTree(from snapshot: QixiCoreSnapshot) {
    // Capture the user's scrubber spine *before* core apply rewrites child order.
    // Light-tree nodes arrive sorted by core id; first-child primary path would jump
    // side branches onto the mainline after every structure refresh.
    let previousPath = variation.currentPathNodeIDs
    let result = variation.apply(from: snapshot, boardMove: { move, color in
      boardMove(fromCoreMove: move, color: color)
    })
    // Quality deltas / topology both affect painted tree colors and edges.
    if result != .noOp {
      invalidateVariationTreeCache()
    }
    let spineIDs = variation.spinePreservingPreviousPath(
      previousPath: previousPath,
      currentID: variation.currentNodeID
    )
    let newMainLine = spineIDs.compactMap { variation.records[$0]?.move }
    let newPly = min(variation.records[variation.currentNodeID]?.ply ?? 0, newMainLine.count)
    // Avoid @Published churn / board cache rebuild when the path is unchanged.
    if newMainLine != mainLine {
      mainLine = newMainLine
    }
    if newPly != currentPly {
      currentPly = newPly
    }
    // Keep variation.currentPathNodeIDs aligned with the scrubber spine.
    if spineIDs != variation.currentPathNodeIDs {
      variation.currentPathNodeIDs = spineIDs
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
    // Board reads analyzeDisplay only — must clear with the candidate cache.
    analyzeDisplay.clear()
    // clear() wipes next-move overlays. Drop the decoration memo so refresh below
    // always re-applies the outline (same ply/key would otherwise early-return and
    // leave no black/white stroke under "no engine").
    lastNextMoveDecorationKey = nil
    refreshNextMoveDecoration()
    invalidateChartPointsCache()
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
        // Fresh core store on every cold open — do not reload previous MCTS/app state.
        let boot = try await coreBackendService.submitCoreRequest(
          .boot(loadLastState: false, firstLaunch: true, expectedBackendEpoch: 0)
        )
        coreBackendEpoch = boot.backendEpoch
        coreRevision = boot.revision
        // Never seed HUD gate with kInvalidNode — that freezes analysis acceptance.
        if boot.currentRoot != UInt32.max {
          coreCurrentRootID = boot.currentRoot
        } else {
          coreCurrentRootID = 0
        }
        coreBootSucceeded = true
        if !mainLine.isEmpty {
          enqueueCurrentMainLineIntoCore(reason: "coreLaunchSampleLine")
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
            reason: "coreLaunchKomi"
          )
          try await submitCoreMutationAndWait(
            .setWideRootNoise(rootNoise, expectedBackendEpoch: 0),
            reason: "coreLaunchRootNoise"
          )
        } catch {
          lastEngineError = localizedEngineError(error, fallbackKey: .engineErrorAnalysisFailed)
          hermesStatus = .offline
        }
      }
    }
    exportAutomationRealDeviceEvidenceIfRequested(
      environment: ProcessInfo.processInfo.environment,
      trigger: .launch
    )
    if selectedEngine != .none {
      transitionHandedToEngineLoad = true
      startAnalysis(
        engine: selectedEngine,
        assumesEngineAlreadyLoaded: false,
        transitionToken: transitionToken
      )
    }
  }

  private func enqueueCurrentMainLineIntoCore(reason: String) {
    variation.coreRootReferenceByNodeID = [Self.variationRootID: .node(0)]
    // Prefer explicit PL (photo recognition / SGF); do not force Black on empty history.
    let sideToMove = rootSideToMove
    let setup = analysisSetupStones
    if !setup.isEmpty {
      submitCoreMutation(
        .applyRecognizedBoard(
          setupStones: setup,
          nextPla: sideToMove,
          expectedBackendEpoch: 0
        ),
        reason: "\(reason)Setup"
      )
    } else {
      submitCoreMutation(
        .newGame(
          komi: komi,
          nextPla: sideToMove,
          expectedBackendEpoch: 0
        ),
        reason: "\(reason)Reset"
      )
    }
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
    // Sync/import only mutated UI state — push board identity into core so analysis
    // does not continue on the previous game under a new mainLine.
    if coreBackendService != nil {
      enqueueCurrentMainLineIntoCore(reason: "coreImportedSnapshot")
      submitCoreMutation(.setKomi(komi, expectedBackendEpoch: 0), reason: "coreImportedKomi")
      submitCoreMutation(.setWideRootNoise(rootNoise, expectedBackendEpoch: 0), reason: "coreImportedRootNoise")
    }
    guard selectedEngine != .none else { return }
    startAnalysis(engine: selectedEngine, assumesEngineAlreadyLoaded: false)
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
      mainLine.isEmpty &&
      currentPly == 0 &&
      komi == Self.defaultKomi &&
      rootNoise == Self.defaultRootNoise &&
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
      nextPlayer: explicitRootSideToMove,
      komi: komi,
      rootNoise: rootNoise,
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

  /// Push a single setKomi / setWideRootNoise for a fully committed UI value.
  /// Not debounced: the number field already commits only once (Done / focus loss).
  private func pushCoreKomiOrNoiseSetting(reason: String) {
    analysisRefreshTask?.cancel()
    guard coreBackendService != nil else {
      let engine = selectedEngine
      guard engine != .none else { return }
      refreshAnalysisIfEngineUnchanged(engine)
      return
    }
    switch reason {
    case "komiChanged":
      submitCoreMutation(.setKomi(komi, expectedBackendEpoch: 0), reason: "coreKomiChanged")
    case "rootNoiseChanged":
      submitCoreMutation(
        .setWideRootNoise(rootNoise, expectedBackendEpoch: 0),
        reason: "coreRootNoiseChanged"
      )
    default:
      break
    }
  }

  private func scheduleAnalysisRefresh(reason: String) {
    // Non-setting refreshes only. Komi / root noise use pushCoreKomiOrNoiseSetting.
    // Product: no core autosaveTick / no app autosave on this path.
    if reason == "komiChanged" || reason == "rootNoiseChanged" {
      pushCoreKomiOrNoiseSetting(reason: reason)
      return
    }
    analysisRefreshTask?.cancel()
    let engine = selectedEngine
    analysisRefreshTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      // In-process core search runs continuously; no periodic checkpoint tick.
      if self.coreBackendService != nil { return }
      guard self.selectedEngine != .none, self.selectedEngine == engine else { return }
      self.refreshAnalysisIfEngineUnchanged(engine)
    }
  }

  private func refreshAnalysisIfEngineUnchanged(_ engine: AnalysisEngine) {
    guard selectedEngine == engine else { return }
    startAnalysis(engine: engine, assumesEngineAlreadyLoaded: true)
  }

  private func refreshVisibleAnalysisForCurrentSettings() {
    if !restoreCachedAnalysisForCurrentPosition() {
      clearVisibleAnalysisAndRefreshAnchor()
    }
  }

  private func restoreCachedAnalysisForCurrentPosition() -> Bool {
    guard let engine = analysisEngineForCachedDisplay else { return false }
    let key = positionCacheKey(
      engine: engine,
      moves: boardMoves,
      setupStones: analysisSetupStones,
      komi: komi,
      rootNoise: rootNoise
    )
    return restoreCachedAnalysis(engine: engine, cacheKey: key)
  }

  private func currentAnalysisCacheKey(for engine: AnalysisEngine) -> String? {
    guard engine == selectedEngine, engine != .none else { return nil }
    if let memoizedCurrentAnalysisCacheKey,
       memoizedCurrentAnalysisCacheEngine == engine {
      return memoizedCurrentAnalysisCacheKey
    }
    let key = positionCacheKey(
      engine: engine,
      moves: boardMoves,
      setupStones: analysisSetupStones,
      komi: komi,
      rootNoise: rootNoise
    )
    memoizedCurrentAnalysisCacheKey = key
    memoizedCurrentAnalysisCacheEngine = engine
    return key
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
    // Board plane is analyzeDisplay, not `candidates` — mirror cache onto overlays.
    analyzeDisplay.applyCached(
      winrate: cached.winrate,
      scoreMean: cached.scoreMean,
      visits: cached.visits,
      candidates: cached.candidates,
      territory: cached.territory
    )
    refreshNextMoveDecoration()
    invalidateChartPointsCache()
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
    invalidateChartPointsCache()
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
    // Ensure NN is not resident before one-shot store blob write under pressure.
    if selectedEngine != .none {
      await applySoftMemoryPressureRelief()
    }
    guard coreBackendService != nil else { return }
    let token = beginBackendTransition(.memoryUnload)
    // No streaming progress: unload is one checkpoint write + free RAM.
    defer { finishBackendTransition(token) }
    updateBackendTransitionProgress(
      token,
      phase: L10n.text(.memoryPressureSavingAndFreeing),
      fraction: 0.2
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
    // Empty mainLine is a valid new-game state — never rewrite it as the demo sample.
    let restoredMainLine = snapshot.mainLine
    mainLine = restoredMainLine
    // Prefer explicit PL from snapshot (photo / SGF); else first-move / Black default.
    explicitRootSideToMove = snapshot.nextPlayer
    komi = snapshot.komi
    rootNoise = QixiAnalysisLimits.normalizedRootNoise(snapshot.rootNoise)
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
      rootNoise: rootNoise,
      // White-first / setup roots: empty history must not always key as Black-to-play.
      rootToMove: rootSideToMove
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
