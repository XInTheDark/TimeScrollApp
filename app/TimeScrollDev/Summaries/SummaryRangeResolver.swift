import Foundation

/// A requested range after snapping to the precision its length allows. `[fromMs, toMs)`.
struct ResolvedSummaryRange: Equatable {
  enum Precision: Int, Comparable {
    case exact, quarterHour, day
    static func < (lhs: Precision, rhs: Precision) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  let fromMs: Int64
  let toMs: Int64
  let precision: Precision

  var isEmpty: Bool { toMs <= fromMs }
}

/// Where one part of a resolved range is read from.
enum AppTimePiece: Equatable {
  /// `ts_snapshot`: short ranges and days that may still change.
  case captures(fromMs: Int64, toMs: Int64)
  /// Stored 15-minute rows of part of a day.
  case quarterHours(day: SessionDayPlanner.Day, fromMs: Int64, toMs: Int64)
  /// A stored 1-day row set.
  case wholeDay(SessionDayPlanner.Day)

  var day: SessionDayPlanner.Day? {
    switch self {
    case .captures: return nil
    case .quarterHours(let day, _, _): return day
    case .wholeDay(let day): return day
    }
  }
}

/// The longer a range, the less exact it has to be, and the cheaper it is to read.
enum SummaryRangeResolver {
  static let exactLimitMs: Int64 = 6 * 60 * 60 * 1000
  static let quarterHourLimitMs: Int64 = 14 * 24 * 60 * 60 * 1000

  static func resolve(fromMs: Int64, toMs: Int64, calendar: Calendar) -> ResolvedSummaryRange {
    guard toMs > fromMs else { return ResolvedSummaryRange(fromMs: fromMs, toMs: fromMs, precision: .exact) }
    let length = toMs - fromMs
    if length <= exactLimitMs {
      return ResolvedSummaryRange(fromMs: fromMs, toMs: toMs, precision: .exact)
    }
    if length <= quarterHourLimitMs {
      return ResolvedSummaryRange(fromMs: AppTimeRollup.floor(fromMs, to: AppTimeRollup.quarterHourMs),
                                  toMs: AppTimeRollup.ceil(toMs, to: AppTimeRollup.quarterHourMs),
                                  precision: .quarterHour)
    }
    let first = SessionDayPlanner.day(containing: fromMs, calendar: calendar)
    let last = SessionDayPlanner.day(containing: toMs - 1, calendar: calendar)
    return ResolvedSummaryRange(fromMs: first.startMs, toMs: last.endMs, precision: .day)
  }

  /// A day can be stored once its captures have stopped changing.
  static func isSettled(_ day: SessionDayPlanner.Day, nowMs: Int64) -> Bool {
    nowMs >= day.endMs + ActivitySessionProvider.settleDelayMs
  }

  /// `splitWholeDays` reads whole days as 15-minute rows, for series finer than a day.
  static func pieces(for range: ResolvedSummaryRange, nowMs: Int64, calendar: Calendar,
                     splitWholeDays: Bool = false) -> [AppTimePiece] {
    guard !range.isEmpty else { return [] }
    if range.precision == .exact { return [.captures(fromMs: range.fromMs, toMs: range.toMs)] }
    return SessionDayPlanner.days(from: range.fromMs, to: range.toMs - 1, calendar: calendar).map { day in
      let from = max(day.startMs, range.fromMs)
      let to = min(day.endMs, range.toMs)
      if !isSettled(day, nowMs: nowMs) { return .captures(fromMs: from, toMs: to) }
      let whole = from == day.startMs && to == day.endMs
      return whole && !splitWholeDays ? .wholeDay(day) : .quarterHours(day: day, fromMs: from, toMs: to)
    }
  }
}
