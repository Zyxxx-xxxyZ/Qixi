import Foundation

/// Compile-only stubs so the incremental smoke can link AnalysisService types
/// without the full native bridge.
struct NativeKataGoAnalysisService: QixiAnalysisService {
  var runtime: QixiAnalysisRuntime { .nativeInProcess }

  func setEngine(_ engine: AnalysisEngine) async throws -> BackendStatusResponse {
    BackendStatusResponse(
      engine: engine.rawValue,
      engineId: nil,
      state: "ready",
      running: false,
      paused: false
    )
  }

  func analyze(
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse {
    AnalysisResponse(
      engine: "none",
      state: "ready",
      positionKey: "",
      winrate: 0.5,
      scoreMean: 0.0,
      visits: 0,
      moves: [],
      ownership: []
    )
  }
}
