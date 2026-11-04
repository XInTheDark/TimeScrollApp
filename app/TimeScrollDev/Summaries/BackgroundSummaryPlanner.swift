import Foundation

/// Which finished periods background generation should fill in. Days come first, newest first, so
/// weeks and months have stored summaries to build on.
enum BackgroundSummaryPlanner {
  static let catchUpDays = 30

  static func pending(nowMs: Int64, calendar: Calendar, stored: Set<Range<Int64>>, skipped: Set<Range<Int64>>,
                      allowance: BackgroundSummaryConditions.Allowance) -> [Range<Int64>] {
    guard allowance != .none else { return [] }
    let dayCount = allowance == .all ? catchUpDays : 1
    let units: [(Calendar.Component, Int)] = [(.day, dayCount), (.weekOfYear, allowance == .all ? 5 : 1), (.month, allowance == .all ? 2 : 1)]
    let earliest = nowMs - Int64(catchUpDays + 1) * 86_400_000
    var pending: [Range<Int64>] = []
    for (unit, count) in units {
      for period in finished(unit, count: count, nowMs: nowMs, calendar: calendar) where period.upperBound >= earliest {
        if !stored.contains(period), !skipped.contains(period) { pending.append(period) }
      }
    }
    return pending
  }

  /// The most recent finished periods of this unit, newest first.
  private static func finished(_ unit: Calendar.Component, count: Int, nowMs: Int64, calendar: Calendar) -> [Range<Int64>] {
    var periods: [Range<Int64>] = []
    var probeMs = nowMs
    var attempts = 0
    while periods.count < count, attempts < count + 2 {
      attempts += 1
      let date = Date(timeIntervalSince1970: TimeInterval(probeMs) / 1000)
      guard let interval = calendar.dateInterval(of: unit, for: date) else { break }
      let start = Int64((interval.start.timeIntervalSince1970 * 1000).rounded())
      let end = Int64((interval.end.timeIntervalSince1970 * 1000).rounded())
      if RangeSummaryPlanner.isStorable(fromMs: start, toMs: end, nowMs: nowMs, calendar: calendar) { periods.append(start..<end) }
      probeMs = start - 1
    }
    return periods
  }
}
