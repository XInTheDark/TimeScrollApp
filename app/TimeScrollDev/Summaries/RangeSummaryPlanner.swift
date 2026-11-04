import Foundation

/// Decides what one summary is made from. Each summary is exactly one model call, so a long range
/// can't set off a chain of generation: it reuses what is stored and covers the rest with sessions.
enum RangeSummaryPlanner {
  struct Plan: Equatable {
    let reused: [StoredRangeSummary]
    /// Parts of the range that no reused summary covers, in time order.
    let gaps: [Range<Int64>]
  }

  /// Largest stored summaries first (months before weeks before days), oldest first among equals, never overlapping.
  /// A stored summary of exactly this range is left out: asking again means replacing it.
  static func plan(fromMs: Int64, toMs: Int64, stored: [StoredRangeSummary]) -> Plan {
    let candidates = stored
      .filter { $0.startMs >= fromMs && $0.endMs <= toMs && !($0.startMs == fromMs && $0.endMs == toMs) }
      .sorted {
        let (left, right) = ($0.endMs - $0.startMs, $1.endMs - $1.startMs)
        return left != right ? left > right : $0.startMs < $1.startMs
      }
    var reused: [StoredRangeSummary] = []
    for summary in candidates where !reused.contains(where: { summary.startMs < $0.endMs && $0.startMs < summary.endMs }) {
      reused.append(summary)
    }
    reused.sort { $0.startMs < $1.startMs }

    var gaps: [Range<Int64>] = []
    var cursor = fromMs
    for summary in reused {
      if summary.startMs > cursor { gaps.append(cursor..<summary.startMs) }
      cursor = summary.endMs
    }
    if cursor < toMs { gaps.append(cursor..<toMs) }
    return Plan(reused: reused, gaps: gaps)
  }

  /// Only calendar days, weeks, months and years that can no longer change are stored.
  static func isStorable(fromMs: Int64, toMs: Int64, nowMs: Int64, calendar: Calendar) -> Bool {
    guard toMs > fromMs, nowMs >= toMs + ActivitySessionProvider.settleDelayMs else { return false }
    let start = Date(timeIntervalSince1970: TimeInterval(fromMs) / 1000)
    for unit in [Calendar.Component.day, .weekOfYear, .month, .year] {
      guard let period = calendar.dateInterval(of: unit, for: start) else { continue }
      if Int64((period.start.timeIntervalSince1970 * 1000).rounded()) == fromMs,
         Int64((period.end.timeIntervalSince1970 * 1000).rounded()) == toMs { return true }
    }
    return false
  }

  /// Most of the budget goes to stored summaries only while sessions still have room.
  static func summariesBudgetBytes(total budget: Int, hasGaps: Bool) -> Int {
    hasGaps ? budget * 6 / 10 : budget
  }
}
