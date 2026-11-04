import Foundation

/// Activity over time. Requested granularity is limited by what the range's precision can answer.
enum AppTimeSeries {
  enum Granularity: Int, Comparable {
    case minute, quarterHour, hour, day
    static func < (lhs: Granularity, rhs: Granularity) -> Bool { lhs.rawValue < rhs.rawValue }

    var ms: Int64? {
      switch self {
      case .minute: return 60_000
      case .quarterHour: return AppTimeRollup.quarterHourMs
      case .hour: return 3_600_000
      case .day: return nil
      }
    }
  }

  struct Point: Equatable {
    let startMs: Int64
    let dwellMs: Int64
    let snapshotCount: Int64
  }

  static func effective(_ requested: Granularity, precision: ResolvedSummaryRange.Precision) -> Granularity {
    switch precision {
    case .exact: return requested
    case .quarterHour: return max(requested, .quarterHour)
    case .day: return .day
    }
  }

  /// Buckets are measured from local midnight, so hours stay on the hour in half-hour time zones.
  static func points(rows: [AppTimeRow], granularity: Granularity, calendar: Calendar) -> [Point] {
    var totals: [Int64: (dwellMs: Int64, count: Int64)] = [:]
    var day: SessionDayPlanner.Day?
    for row in rows {
      if day == nil || row.bucketMs < day!.startMs || row.bucketMs >= day!.endMs {
        day = SessionDayPlanner.day(containing: row.bucketMs, calendar: calendar)
      }
      let dayStart = day!.startMs
      let start = granularity.ms.map { dayStart + (row.bucketMs - dayStart) / $0 * $0 } ?? dayStart
      let entry = totals[start] ?? (0, 0)
      totals[start] = (entry.dwellMs + row.dwellMs, entry.count + row.snapshotCount)
    }
    return totals.keys.sorted().map { Point(startMs: $0, dwellMs: totals[$0]!.dwellMs, snapshotCount: totals[$0]!.count) }
  }
}
