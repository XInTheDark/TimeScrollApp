import Foundation
@testable import TimeScroll

/// Synthetic screen captures for session tests: each screen shows words from its topic, the app's
/// own interface text, and text that is on screen everywhere (menu bar, dock, clock).
struct SessionFixture {
  struct Capture {
    let timeMs: Int64
    let app: Int32
    let text: String
  }

  /// Deterministic generator (SplitMix64), so fixtures are identical on every run.
  struct Random {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
  }

  static let globalChrome = ["Finder", "File", "Edit", "View", "Window", "Help", "Wednesday", "Battery", "WiFi", "Spotlight"]

  static func topic(_ name: String, size: Int = 120) -> [String] {
    (0..<size).map { "\(name)word\(Self.letters($0))" }
  }

  static func appChrome(_ app: Int32) -> [String] {
    (0..<25).map { "app\(Self.letters(Int(app)))chrome\(Self.letters($0))" }
  }

  private static func letters(_ value: Int) -> String {
    var value = value
    var result = ""
    repeat {
      result.append(Character(UnicodeScalar(UInt8(97 + value % 26))))
      value /= 26
    } while value > 0
    return result
  }

  var captures: [Capture] = []
  var random = Random(seed: 42)
  /// How far each topic has been scrolled, so returning to a task resumes where it left off.
  private var scrolled: [String: Int64] = [:]

  /// Appends captures every `intervalMs` for `minutes`, cycling through `apps` every `switchEveryMs`,
  /// each screen showing 60 words of `topic` (or no text when `topic` is empty).
  /// `resume: false` starts the topic from the top again instead of where it was left.
  mutating func work(topic: [String], apps: [Int32], minutes: Double, startMs: Int64? = nil,
                     intervalMs: Int64 = 5_000, switchEveryMs: Int64 = 40_000, resume: Bool = true) {
    let start = startMs ?? (captures.last.map { $0.timeMs + intervalMs } ?? 1_700_000_000_000)
    let end = start + Int64(minutes * 60_000)
    let key = topic.first ?? ""
    let scrolledBefore = resume ? scrolled[key, default: 0] : 0
    defer { scrolled[key] = scrolledBefore + (end - start) }
    var time = start
    while time < end {
      let app = apps[Int(((time - start) / switchEveryMs) % Int64(apps.count))]
      var words = Self.globalChrome + Self.appChrome(app)
      if !topic.isEmpty {
        // A scrolling window over the topic: neighbouring screens share most words.
        let offset = Int((scrolledBefore + time - start) / 20_000) % topic.count
        for index in 0..<60 { words.append(topic[(offset + index + random.int(4)) % topic.count]) }
      }
      captures.append(Capture(timeMs: time, app: app, text: topic.isEmpty ? "" : words.joined(separator: " ")))
      time += intervalMs
    }
  }

  /// Samples and sketch table, deduplicating identical texts as the database does.
  func samples() -> (samples: [SessionSample], sketches: [[UInt32]]) {
    var sketchIndex: [String: Int32] = [:]
    var sketches: [[UInt32]] = []
    let samples = captures.map { capture -> SessionSample in
      guard !capture.text.isEmpty else { return SessionSample(timeMs: capture.timeMs, app: capture.app, sketch: -1) }
      if let index = sketchIndex[capture.text] {
        return SessionSample(timeMs: capture.timeMs, app: capture.app, sketch: index)
      }
      let index = Int32(sketches.count)
      sketches.append(SessionTextSketch.make(from: capture.text))
      sketchIndex[capture.text] = index
      return SessionSample(timeMs: capture.timeMs, app: capture.app, sketch: index)
    }
    return (samples, sketches)
  }

  func segment(_ sensitivity: SessionSensitivity = .balanced) -> SessionSegmenter.Result {
    let (samples, sketches) = samples()
    return SessionSegmenter.segment(samples: samples, sketches: sketches,
                                    parameters: SessionSegmenter.Parameters(sensitivity: sensitivity))
  }
}
