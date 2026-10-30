import Foundation

/// What was captured on one calendar day.
struct DayActivity: Equatable {
  /// Wall-clock time with capture running (not a snapshot count).
  var coveredMs: Int64 = 0
  var snapshotCount = 0
}

/// Turns stored captures into per-day recorded time.
enum DayActivityCalculator {
  /// Screen snapshots are skipped while the screen is unchanged, so a gap up to this long between two
  /// snapshots still counts as recorded time. A longer gap means capture was not running.
  static let maxScreenGapMs: Int64 = 5 * 60 * 1000

  /// `intervals` must be sorted by `startMs`.
  static func activity(intervals: [CaptureInterval], calendar: Calendar) -> [Date: DayActivity] {
    var result: [Date: DayActivity] = [:]
    for interval in intervals {
      let day = calendar.startOfDay(for: date(interval.startMs))
      result[day, default: DayActivity()].snapshotCount += 1
    }
    for span in mergedSpans(intervals) {
      var cursor = span.lowerBound
      while cursor < span.upperBound {
        let day = calendar.startOfDay(for: date(cursor))
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let end = min(span.upperBound, Int64(nextDay.timeIntervalSince1970 * 1000))
        result[day, default: DayActivity()].coveredMs += end - cursor
        cursor = end
      }
    }
    return result
  }

  /// Screen snapshots cover the time until the next one (capped); audio covers its own length.
  /// Overlapping spans are merged so simultaneous screen and audio capture counts once.
  private static func mergedSpans(_ intervals: [CaptureInterval]) -> [Range<Int64>] {
    var spans: [Range<Int64>] = []
    let screen = intervals.filter { !$0.isAudio }
    for (index, interval) in screen.enumerated() {
      guard index + 1 < screen.count else { continue }
      let gap = min(screen[index + 1].startMs - interval.startMs, maxScreenGapMs)
      if gap > 0 { spans.append(interval.startMs..<(interval.startMs + gap)) }
    }
    for interval in intervals where interval.isAudio {
      if let end = interval.endMs, end > interval.startMs { spans.append(interval.startMs..<end) }
    }
    spans.sort { $0.lowerBound < $1.lowerBound }

    var merged: [Range<Int64>] = []
    for span in spans {
      if let last = merged.last, span.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
      } else {
        merged.append(span)
      }
    }
    return merged
  }

  private static func date(_ ms: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
  }
}
