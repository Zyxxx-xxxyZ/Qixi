import Foundation

#if !QIXI_NATIVE_RELEASE
struct HTTPBridgeAnalysisService: QixiAnalysisService {
  var runtime: QixiAnalysisRuntime { .httpBridge }
  var client: any QixiHTTPAnalysisClient

  init(client: any QixiHTTPAnalysisClient = BackendClient()) {
    self.client = client
  }

  func setEngine(_ engine: AnalysisEngine) async throws -> BackendStatusResponse {
    try await client.setEngine(engine)
  }

  func analyze(
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse {
    try QixiAnalysisInputValidator.validate(
      moves: moves,
      setupStones: setupStones,
      maxVisits: maxVisits,
      komi: komi,
      rootNoise: rootNoise
    )
    var response = try await client.analyze(
      moves: moves,
      setupStones: setupStones,
      maxVisits: maxVisits,
      komi: komi,
      rootNoise: rootNoise
    )
    guard let engine = Self.analysisEngine(from: response.engine) else {
      throw QixiAnalysisResponseValidationError.unknownEngine(response.engine)
    }
    try QixiAnalysisResponseValidator.validate(response, expectedEngine: engine)
    response.positionKey = QixiPositionIdentity.cacheKey(
      engine: engine,
      moves: moves,
      setupStones: setupStones,
      komi: komi,
      rootNoise: rootNoise
    )
    return response
  }

  private static func analysisEngine(from rawEngine: String) -> AnalysisEngine? {
    if let engine = AnalysisEngine(rawValue: rawEngine) {
      return engine
    }
    return AnalysisEngine.allCases.first { engine in
      engine != .none && rawEngine.hasSuffix(":\(engine.rawValue)")
    }
  }
}
#endif
