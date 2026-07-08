import Foundation

#if !QIXI_NATIVE_RELEASE
extension QixiRuntimeConfig {
  static let backendURLDefaultsKey = "qixi.backendBaseURL"
  static let backendURLEnvironmentKey = "QIXI_BACKEND_URL"
  static let backendURLInfoPlistKey = "QixiBackendBaseURL"
  static let defaultBackendBaseURL = URL(string: "http://127.0.0.1:8765")!

  static func backendBaseURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    bundle: Bundle = .main
  ) -> URL {
    if let value = environment[backendURLEnvironmentKey], let url = normalizedURL(value) {
      return url
    }
    if let value = defaults.string(forKey: backendURLDefaultsKey), let url = normalizedURL(value) {
      return url
    }
    if let value = bundle.object(forInfoDictionaryKey: backendURLInfoPlistKey) as? String,
       let url = normalizedURL(value) {
      return url
    }
    return defaultBackendBaseURL
  }

  private static func normalizedURL(_ rawValue: String) -> URL? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
    guard let components = URLComponents(string: withScheme),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          components.host != nil else {
      return nil
    }
    return components.url
  }
}

protocol QixiHTTPAnalysisClient {
  func setEngine(_ engine: AnalysisEngine) async throws -> BackendStatusResponse
  func analyze(
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse
}

extension QixiHTTPAnalysisClient {
  func analyze(
    moves: [BoardMove],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse {
    try await analyze(
      moves: moves,
      setupStones: [],
      maxVisits: maxVisits,
      komi: komi,
      rootNoise: rootNoise
    )
  }
}

enum BackendClientResponseError: Error, Equatable, LocalizedError {
  case nonHTTPResponse
  case unacceptableStatusCode(Int)
  case missingJSONContentType(String?)
  case responseTooLarge(bytes: Int, limit: Int)

  var errorDescription: String? {
    switch self {
    case .nonHTTPResponse:
      return "Backend response was not an HTTP response."
    case .unacceptableStatusCode(let statusCode):
      return "Backend response returned unacceptable HTTP status \(statusCode)."
    case .missingJSONContentType(let contentType):
      return "Backend response must use application/json content type, got \(contentType ?? "missing")."
    case .responseTooLarge(let bytes, let limit):
      return "Backend response body has \(bytes) bytes, exceeding the \(limit) byte limit."
    }
  }
}

struct BackendClient: QixiHTTPAnalysisClient {
  static let maxResponseBytes = 1024 * 1024

  var baseURL = QixiRuntimeConfig.backendBaseURL()
  var session = URLSession.shared

  func setEngine(_ engine: AnalysisEngine) async throws -> BackendStatusResponse {
    try await post("api/engine", body: EngineRequest(engine: engine.rawValue), as: BackendStatusResponse.self)
  }

  func analyze(
    moves: [BoardMove],
    setupStones: [BoardSetupStone],
    maxVisits: Int,
    komi: Double,
    rootNoise: Double
  ) async throws -> AnalysisResponse {
    let payload = AnalysisRequest(
      moves: moves,
      setupStones: setupStones,
      maxVisits: maxVisits,
      komi: komi,
      rootNoise: rootNoise
    )
    return try await post("api/analyze", body: payload, as: AnalysisResponse.self)
  }

  private func post<Request: Encodable, Response: Decodable>(
    _ path: String,
    body: Request,
    as responseType: Response.Type
  ) async throws -> Response {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    let (data, urlResponse) = try await session.data(for: request)
    guard let http = urlResponse as? HTTPURLResponse else {
      throw BackendClientResponseError.nonHTTPResponse
    }
    guard 200..<300 ~= http.statusCode else {
      throw BackendClientResponseError.unacceptableStatusCode(http.statusCode)
    }
    let contentType = http.value(forHTTPHeaderField: "Content-Type")
    guard Self.isJSONContentType(contentType) else {
      throw BackendClientResponseError.missingJSONContentType(contentType)
    }
    guard data.count <= Self.maxResponseBytes else {
      throw BackendClientResponseError.responseTooLarge(bytes: data.count, limit: Self.maxResponseBytes)
    }
    let objectData = try QixiStrictJSONDocumentValidator.validatedObjectData(
      data,
      label: "Qixi HTTP bridge response",
      maxBytes: Self.maxResponseBytes
    )
    return try JSONDecoder().decode(Response.self, from: objectData)
  }

  private static func isJSONContentType(_ rawValue: String?) -> Bool {
    guard let rawValue else { return false }
    let mediaType = rawValue
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return mediaType == "application/json"
  }
}
#endif
