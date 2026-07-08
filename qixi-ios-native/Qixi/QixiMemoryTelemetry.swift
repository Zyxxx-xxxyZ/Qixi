import Darwin
import Foundation

struct QixiProcessMemoryStats: Equatable {
  var physFootprintBytes: UInt64
  var residentSizeBytes: UInt64
  var virtualSizeBytes: UInt64
  var internalBytes: UInt64
  var compressedBytes: UInt64
}

struct QixiMemoryTelemetryContext: Equatable {
  var selectedEngine: String
  var hermesStatus: String
  var currentPly: Int
  var mainLineCount: Int
  var rootVisits: Int
  var candidateCount: Int
  var topCandidateVisits: Int
  var showTerritory: Bool

  static let empty = QixiMemoryTelemetryContext(
    selectedEngine: "none",
    hermesStatus: "ready",
    currentPly: 0,
    mainLineCount: 0,
    rootVisits: 0,
    candidateCount: 0,
    topCandidateVisits: 0,
    showTerritory: false
  )
}

struct QixiMemoryTelemetrySample: Codable, Equatable {
  var schemaVersion = 1
  var recordedAt: Date
  var uptimeSeconds: Double
  var sampleReason: String
  var physFootprintBytes: UInt64
  var residentSizeBytes: UInt64
  var virtualSizeBytes: UInt64
  var internalBytes: UInt64
  var compressedBytes: UInt64
  var peakPhysFootprintBytes: UInt64
  var peakResidentSizeBytes: UInt64
  var selectedEngine: String
  var hermesStatus: String
  var currentPly: Int
  var mainLineCount: Int
  var rootVisits: Int
  var candidateCount: Int
  var topCandidateVisits: Int
  var showTerritory: Bool
}

extension HermesStatus {
  var telemetryValue: String {
    switch self {
    case .ready: return "ready"
    case .loading: return "loading"
    case .offline: return "offline"
    }
  }
}

actor QixiMemoryTelemetryWriter {
  static let filename = "memory-telemetry.jsonl"
  static let maxLogBytes: UInt64 = 32 * 1024 * 1024

  let logURL: URL
  private let encoder: JSONEncoder

  init(logURL: URL = QixiMemoryTelemetryWriter.defaultLogURL()) {
    self.logURL = logURL
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
  }

  static func defaultLogURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base
      .appendingPathComponent("Qixi", isDirectory: true)
      .appendingPathComponent(filename, isDirectory: false)
  }

  func append(_ sample: QixiMemoryTelemetrySample) {
    do {
      try rotateIfNeeded()
      try FileManager.default.createDirectory(
        at: logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      var data = try encoder.encode(sample)
      data.append(0x0A)
      if FileManager.default.fileExists(atPath: logURL.path) {
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: logURL, options: [.atomic])
      }
    } catch {
      print("[QixiMemory] log-write-failed error=\(error)")
    }
  }

  private func rotateIfNeeded() throws {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
          let byteCount = attributes[.size] as? NSNumber,
          byteCount.uint64Value > Self.maxLogBytes else {
      return
    }
    let rotatedURL = logURL.deletingLastPathComponent().appendingPathComponent(
      "memory-telemetry.previous.jsonl",
      isDirectory: false
    )
    if FileManager.default.fileExists(atPath: rotatedURL.path) {
      try FileManager.default.removeItem(at: rotatedURL)
    }
    try FileManager.default.moveItem(at: logURL, to: rotatedURL)
  }
}

@MainActor
final class QixiMemorySampler {
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .memory
    return formatter
  }()

  private let sampleInterval: TimeInterval
  private let writer: QixiMemoryTelemetryWriter
  private let contextProvider: @MainActor () -> QixiMemoryTelemetryContext
  private var timer: Timer?
  private var peakPhysFootprintBytes: UInt64 = 0
  private var peakResidentSizeBytes: UInt64 = 0

  init(
    sampleInterval: TimeInterval = 1.0,
    writer: QixiMemoryTelemetryWriter = QixiMemoryTelemetryWriter(),
    contextProvider: @escaping @MainActor () -> QixiMemoryTelemetryContext
  ) {
    self.sampleInterval = sampleInterval
    self.writer = writer
    self.contextProvider = contextProvider
  }

  func start() {
    guard timer == nil else { return }
    record(reason: "start")
    timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.record(reason: "interval")
      }
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  func stop(reason: String = "stop") {
    record(reason: reason)
    timer?.invalidate()
    timer = nil
  }

  func recordLifecycle(reason: String) {
    record(reason: "lifecycle:\(reason)")
  }

  func record(reason: String) {
    guard let stats = Self.currentProcessMemoryStats() else {
      print("[QixiMemory] sample-failed reason=\(reason)")
      return
    }
    peakPhysFootprintBytes = max(peakPhysFootprintBytes, stats.physFootprintBytes)
    peakResidentSizeBytes = max(peakResidentSizeBytes, stats.residentSizeBytes)
    let context = contextProvider()
    let sample = QixiMemoryTelemetrySample(
      recordedAt: Date(),
      uptimeSeconds: ProcessInfo.processInfo.systemUptime,
      sampleReason: reason,
      physFootprintBytes: stats.physFootprintBytes,
      residentSizeBytes: stats.residentSizeBytes,
      virtualSizeBytes: stats.virtualSizeBytes,
      internalBytes: stats.internalBytes,
      compressedBytes: stats.compressedBytes,
      peakPhysFootprintBytes: peakPhysFootprintBytes,
      peakResidentSizeBytes: peakResidentSizeBytes,
      selectedEngine: context.selectedEngine,
      hermesStatus: context.hermesStatus,
      currentPly: context.currentPly,
      mainLineCount: context.mainLineCount,
      rootVisits: context.rootVisits,
      candidateCount: context.candidateCount,
      topCandidateVisits: context.topCandidateVisits,
      showTerritory: context.showTerritory
    )
    print(Self.consoleLine(for: sample))
    Task {
      await writer.append(sample)
    }
  }

  static func currentProcessMemoryStats() -> QixiProcessMemoryStats? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return QixiProcessMemoryStats(
      physFootprintBytes: UInt64(info.phys_footprint),
      residentSizeBytes: UInt64(info.resident_size),
      virtualSizeBytes: UInt64(info.virtual_size),
      internalBytes: UInt64(info.internal),
      compressedBytes: UInt64(info.compressed)
    )
  }

  private static func consoleLine(for sample: QixiMemoryTelemetrySample) -> String {
    "[QixiMemory] reason=\(sample.sampleReason) " +
      "footprint=\(format(bytes: sample.physFootprintBytes)) " +
      "rss=\(format(bytes: sample.residentSizeBytes)) " +
      "peakFootprint=\(format(bytes: sample.peakPhysFootprintBytes)) " +
      "engine=\(sample.selectedEngine) status=\(sample.hermesStatus) " +
      "ply=\(sample.currentPly)/\(sample.mainLineCount) " +
      "visits=\(sample.rootVisits) candidates=\(sample.candidateCount)"
  }

  private static func format(bytes: UInt64) -> String {
    byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
  }
}
