import Foundation

/// A selected span of time, `[fromMs, toMs)`, on whole seconds so the date fields show exactly what
/// is selected.
struct TimelineRange: Equatable, Sendable {
  let fromMs: Int64
  let toMs: Int64

  init?(fromMs: Int64, toMs: Int64) {
    guard fromMs < toMs else { return nil }
    self.fromMs = fromMs
    self.toMs = toMs
  }

  /// The whole seconds covering two times, in either order, including a capture at either time.
  static func covering(_ first: Int64, _ second: Int64) -> TimelineRange {
    let lower = min(first, second)
    let upper = max(first, second)
    let from = Int64((Double(lower) / 1000).rounded(.down)) * 1000
    let to = Int64((Double(upper + 1) / 1000).rounded(.up)) * 1000
    return TimelineRange(fromMs: from, toMs: to)!
  }

  var durationMs: Int64 { toMs - fromMs }

  /// A new start; a start at or after the end moves the end, so the range stays valid.
  func withFrom(_ ms: Int64) -> TimelineRange {
    TimelineRange(fromMs: ms, toMs: ms < toMs ? toMs : ms + Self.minimumEditedDurationMs)!
  }

  /// A new end; an end at or before the start moves the start, so the range stays valid.
  func withTo(_ ms: Int64) -> TimelineRange {
    TimelineRange(fromMs: ms > fromMs ? fromMs : ms - Self.minimumEditedDurationMs, toMs: ms)!
  }

  private static let minimumEditedDurationMs: Int64 = 60_000
}

extension SnapshotRangeFilter {
  /// The rows of `range` that `query` shows; nil for a text search, whose matches can't be expressed
  /// as a filter.
  init?(range: TimelineRange, query: TimelineQuery) {
    guard query.text.isEmpty else { return nil }
    self.init(fromMs: max(range.fromMs, query.startMs ?? range.fromMs),
              // The query's end is inclusive.
              toMs: min(range.toMs, query.endMs.map { $0 + 1 } ?? range.toMs),
              appBundleIds: query.appBundleIds ?? [],
              captureKinds: query.captureKinds ?? [],
              audioSourceKinds: query.audioSourceKinds ?? [])
  }
}
