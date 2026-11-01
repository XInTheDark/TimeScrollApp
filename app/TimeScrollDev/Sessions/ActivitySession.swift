import Foundation

/// A stretch of related screen activity: what the user was working on, possibly across several
/// apps. Named "activity" session to keep it apart from `ts_usage_session` (app running time).
struct ActivitySession: Identifiable, Hashable {
  struct AppShare: Hashable {
    let bundleId: String?
    let name: String?
    /// Time spent in the app within the session (each capture counts until the next, capped).
    let ms: Int64
  }

  /// The first snapshot's id, stable across recomputation while the session start stays put.
  let id: Int64
  let startMs: Int64
  /// Start time of the last screen snapshot in the session.
  let endMs: Int64
  let snapshotCount: Int
  /// Apps by time spent, largest first (at most `SessionSummarizer.maxApps`).
  let apps: [AppShare]
  /// The session's most distinctive words, most distinctive first; may be empty.
  let keywords: [String]

  var durationMs: Int64 { max(0, endMs - startMs) }

  func contains(timeMs: Int64, toleranceMs: Int64 = 0) -> Bool {
    timeMs >= startMs - toleranceMs && timeMs <= endMs + toleranceMs
  }

  /// Apps worth naming in a title: the main one, plus others holding at least 15% of the time.
  var titleApps: [AppShare] {
    let total = max(1, apps.reduce(0) { $0 + $1.ms })
    return apps.enumerated().filter { $0.offset == 0 || $0.element.ms * 100 >= total * 15 }.prefix(3).map(\.element)
  }

  var title: String {
    let names = titleApps.map { $0.name ?? $0.bundleId ?? "Unknown" }
    return names.isEmpty ? "Session" : names.joined(separator: ", ")
  }

  /// Title plus keywords, e.g. "Xcode · Safari — TimelineBarView, ScreenCaptureKit".
  var label: String {
    keywords.isEmpty ? title : "\(title) — \(keywords.joined(separator: ", "))"
  }
}
