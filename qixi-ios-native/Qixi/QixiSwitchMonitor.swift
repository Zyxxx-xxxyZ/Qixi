import Foundation
import SwiftUI

/// Live on-device model-switch diagnostic (placed between variation tree and engine strip).
/// Records wall-clock phases so a multi-second stall can be attributed without pulling logs.
@MainActor
final class QixiSwitchMonitor: ObservableObject {
  struct Event: Identifiable, Equatable {
    let id: UInt64
    let ms: Int
    let label: String
  }

  @Published private(set) var isSwitching = false
  @Published private(set) var fromEngine = "—"
  @Published private(set) var toEngine = "—"
  @Published private(set) var phase = "idle"
  @Published private(set) var elapsedMs = 0
  @Published private(set) var events: [Event] = []
  /// Compact one-line last result for the header.
  @Published private(set) var lastHeader = "switch: idle"
  /// Multi-line body (core breakdown + recent events).
  @Published private(set) var bodyText = "Tap a model to measure."
  @Published private(set) var selectedEngine = "none"
  @Published private(set) var loadedEngine = "none"
  @Published private(set) var hermes = "ready"
  @Published private(set) var boardBlocked = false
  @Published private(set) var rootVisits = 0
  @Published private(set) var lastWallMs: Int?
  @Published private(set) var lastSetEngineMs: Int?
  @Published private(set) var lastCoreSelectorMs: Int?
  @Published private(set) var lastCoreTotalMs: Int?

  private var wallStart: ContinuousClock.Instant?
  private var nextEventID: UInt64 = 1
  private var tickTask: Task<Void, Never>?
  private var logPollTask: Task<Void, Never>?
  private var logByteOffset: UInt64 = 0
  private var seenLogFingerprints = Set<String>()
  private var markedFirstVisit = false
  private var sessionID: UInt64 = 0

  private static let maxEvents = 24

  func refreshSnapshot(
    selected: AnalysisEngine,
    loaded: AnalysisEngine,
    hermes: HermesStatus,
    boardBlocked: Bool,
    rootVisits: Int
  ) {
    selectedEngine = selected.rawValue
    loadedEngine = loaded.rawValue
    self.hermes = hermes.telemetryValue
    self.boardBlocked = boardBlocked
    self.rootVisits = rootVisits
    if isSwitching, !markedFirstVisit, rootVisits > 0 {
      markedFirstVisit = true
      mark("first_visits", detail: "visits=\(rootVisits)")
    }
    rebuildBody()
  }

  func begin(from: AnalysisEngine, to: AnalysisEngine) {
    sessionID &+= 1
    let sid = sessionID
    tickTask?.cancel()
    logPollTask?.cancel()
    isSwitching = true
    fromEngine = from.rawValue
    toEngine = to.rawValue
    phase = "ui_tap"
    elapsedMs = 0
    events = []
    markedFirstVisit = false
    lastHeader = "switch: \(from.rawValue) → \(to.rawValue) …"
    wallStart = ContinuousClock.now
    mark("ui_tap", detail: "\(from.rawValue)→\(to.rawValue)")
    startTicker(session: sid)
    startLogPoll(session: sid)
    rebuildBody()
  }

  func mark(_ label: String, detail: String? = nil) {
    guard isSwitching, let start = wallStart else { return }
    let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
    elapsedMs = ms
    phase = label
    let text: String
    if let detail, !detail.isEmpty {
      text = "+\(ms)ms  \(label)  \(detail)"
    } else {
      text = "+\(ms)ms  \(label)"
    }
    appendEvent(ms: ms, label: text)
    // Also mirror into the shared timing file for offline pull.
    appendTimingFileLine("[qixi-switch] UI_phase ms=\(ms) phase=\(label) \(detail ?? "")")
    rebuildBody()
  }

  /// Parse core/Swift setEngine status text for engineSelector_ms / wall_ms / etc.
  func noteSetEngineStatus(_ status: String, wallMs: Int) {
    lastSetEngineMs = wallMs
    if let v = Self.firstInt(in: status, key: "engineSelector_ms") {
      lastCoreSelectorMs = v
    }
    if let v = Self.firstInt(in: status, key: "handle_ms") ?? Self.firstInt(in: status, key: "total_ms") {
      lastCoreTotalMs = v
    }
    mark("setEngine_done", detail: "wall=\(wallMs)ms \(Self.compactCoreBits(status))")
  }

  func finish(success: Bool, wallMs: Int) {
    lastWallMs = wallMs
    elapsedMs = wallMs
    isSwitching = false
    phase = success ? "unlocked" : "failed"
    tickTask?.cancel()
    tickTask = nil
    // Keep log poll briefly to catch trailing core lines, then stop.
    let sid = sessionID
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard let self, self.sessionID == sid else { return }
      self.pollTimingLogOnce()
      self.logPollTask?.cancel()
      self.logPollTask = nil
      self.rebuildBody()
    }
    mark(success ? "ui_unlock" : "ui_fail", detail: "wall=\(wallMs)ms")
    let sel = lastCoreSelectorMs.map { "\($0)" } ?? "?"
    let setE = lastSetEngineMs.map { "\($0)" } ?? "?"
    lastHeader =
      "last: \(fromEngine)→\(toEngine) wall=\(wallMs)ms setEngine=\(setE)ms coreSel=\(sel)ms \(success ? "OK" : "FAIL")"
    rebuildBody()
  }

  func noteSuperseded() {
    mark("superseded")
    isSwitching = false
    phase = "superseded"
    tickTask?.cancel()
    tickTask = nil
    logPollTask?.cancel()
    logPollTask = nil
    lastHeader = "last: superseded \(fromEngine)→\(toEngine)"
    rebuildBody()
  }

  // MARK: - Private

  private func startTicker(session: UInt64) {
    tickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.sessionID == session, self.isSwitching, let start = self.wallStart else { return }
        self.elapsedMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        self.rebuildBody()
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private func startLogPoll(session: UInt64) {
    // Read only new bytes of the core timing file while a switch is active.
    logByteOffset = currentLogSize()
    logPollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.sessionID == session else { return }
        self.pollTimingLogOnce()
        try? await Task.sleep(for: .milliseconds(80))
        if !self.isSwitching { return }
      }
    }
  }

  private func timingLogURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("qixi-switch-timing.log")
  }

  private func currentLogSize() -> UInt64 {
    let path = timingLogURL().path
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? NSNumber else { return 0 }
    return size.uint64Value
  }

  private func pollTimingLogOnce() {
    let url = timingLogURL()
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    let size = currentLogSize()
    if size < logByteOffset {
      logByteOffset = 0
      seenLogFingerprints.removeAll(keepingCapacity: true)
    }
    guard size > logByteOffset else { return }
    do {
      try handle.seek(toOffset: logByteOffset)
      guard let data = try handle.readToEnd(), !data.isEmpty,
            let text = String(data: data, encoding: .utf8) else { return }
      logByteOffset = size
      for raw in text.split(whereSeparator: \.isNewline) {
        let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.contains("[qixi-switch]") else { continue }
        // Skip pure UI echoes we wrote ourselves (avoid duplicate noise).
        if line.contains("UI_phase") || line.contains("UI_wall") { continue }
        let fp = String(line.suffix(120))
        guard seenLogFingerprints.insert(fp).inserted else { continue }
        // Prefer wall clock relative to switch start when the line is first observed.
        // (Core lines themselves do not carry a UI epoch; poll is ~80ms so this is fine
        // once setEngine is no longer starved for tens of seconds.)
        let ms = wallStart.map { Int((ContinuousClock.now - $0) / .milliseconds(1)) } ?? elapsedMs
        appendEvent(ms: ms, label: "+\(ms)ms  core  \(Self.shortenCoreLine(line))")
        if let v = Self.firstInt(in: line, key: "engineSelector_ms") {
          lastCoreSelectorMs = v
        }
        if let v = Self.firstInt(in: line, key: "total_ms") ?? Self.firstInt(in: line, key: "handle_ms") {
          lastCoreTotalMs = v
        }
        if let v = Self.firstInt(in: line, key: "wall_ms"), line.contains("submitAndWait_selectEngine") {
          lastCoreTotalMs = v
        }
        if line.contains("loadModel") {
          phase = "loadModel"
        } else if line.contains("engineSelector") {
          phase = "engineSelector"
        } else if line.contains("begin model") {
          phase = "core_begin"
          // Highlight starvation: core begin long after setEngine_start = actor/mutex bug.
          if ms > 2000 {
            appendEvent(ms: ms, label: "+\(ms)ms  !! STARVE core_begin delayed \(ms)ms")
          }
        } else if line.contains("done model") {
          phase = "core_done"
        } else if line.contains("bg_destroy") {
          phase = "bg_destroy"
        }
      }
      rebuildBody()
    } catch {
      // Best-effort only.
    }
  }

  private func appendEvent(ms: Int, label: String) {
    let id = nextEventID
    nextEventID &+= 1
    events.append(Event(id: id, ms: ms, label: label))
    if events.count > Self.maxEvents {
      events.removeFirst(events.count - Self.maxEvents)
    }
  }

  private func rebuildBody() {
    var lines: [String] = []
    lines.append(
      "sel=\(selectedEngine) load=\(loadedEngine) hermes=\(hermes) blocked=\(boardBlocked ? "Y" : "N") visits=\(rootVisits)"
    )
    if isSwitching {
      lines.append("LIVE +\(elapsedMs)ms  phase=\(phase)  \(fromEngine)→\(toEngine)")
    } else if let wall = lastWallMs {
      let setE = lastSetEngineMs.map(String.init) ?? "?"
      let coreS = lastCoreSelectorMs.map(String.init) ?? "?"
      let coreT = lastCoreTotalMs.map(String.init) ?? "?"
      lines.append("wall=\(wall)ms setEngine=\(setE)ms coreSel=\(coreS)ms coreTot=\(coreT)ms")
    }
    // Newest events last (bottom of panel scrolls with eyes).
    let tail = events.suffix(10)
    for event in tail {
      lines.append(event.label)
    }
    bodyText = lines.joined(separator: "\n")
  }

  private func appendTimingFileLine(_ line: String) {
    let url = timingLogURL()
    guard let data = (line + "\n").data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }

  private static func firstInt(in text: String, key: String) -> Int? {
    // Match key=123 or key:123
    let patterns = ["\(key)=", "\(key):"]
    for prefix in patterns {
      guard let r = text.range(of: prefix) else { continue }
      let rest = text[r.upperBound...]
      var digits = ""
      for ch in rest {
        if ch.isNumber {
          digits.append(ch)
        } else if !digits.isEmpty {
          break
        } else if ch == " " || ch == "\t" {
          continue
        } else {
          break
        }
      }
      if let v = Int(digits) { return v }
    }
    return nil
  }

  private static func compactCoreBits(_ status: String) -> String {
    var parts: [String] = []
    for key in ["engineSelector_ms", "prepare_ms", "rekey_ms", "playout_ms", "handle_ms", "wall_ms", "nodes", "store_MB"] {
      if let v = firstInt(in: status, key: key) {
        parts.append("\(key)=\(v)")
      }
    }
    return parts.joined(separator: " ")
  }

  private static func shortenCoreLine(_ line: String) -> String {
    var s = line
    if let r = s.range(of: "[qixi-switch] ") {
      s = String(s[r.upperBound...])
    }
    if s.count > 96 {
      return String(s.prefix(96)) + "…"
    }
    return s
  }
}

/// Compact live panel between the variation tree and engine selector.
struct QixiSwitchMonitorView: View {
  @ObservedObject var monitor: QixiSwitchMonitor

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Circle()
          .fill(monitor.isSwitching ? QixiColor.hermesOrange : QixiColor.hermesBlue)
          .frame(width: 8, height: 8)
        Text(monitor.lastHeader)
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(QixiColor.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Spacer(minLength: 0)
        if monitor.isSwitching {
          Text("+\(monitor.elapsedMs)ms")
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(QixiColor.hermesOrange)
        }
      }
      ScrollView(.vertical, showsIndicators: true) {
        Text(monitor.bodyText)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(QixiColor.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 118)
    .background(QixiColor.controlSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(
          monitor.isSwitching ? QixiColor.hermesOrange.opacity(0.55) : QixiColor.separator,
          lineWidth: monitor.isSwitching ? 1.2 : 0.8
        )
    )
    .accessibilityIdentifier("switch-monitor-panel")
  }
}
