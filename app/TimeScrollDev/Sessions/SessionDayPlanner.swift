import Foundation

/// Sessions are computed and stored per local calendar day. Each day is segmented with a few hours
/// of context on both sides, and owns the sessions that start within it, so a session running past
/// midnight is found whole by the day it started in.
enum SessionDayPlanner {
  static let contextMarginMs: Int64 = 3 * 60 * 60 * 1000

  struct Day: Hashable {
    let startMs: Int64
    /// Exclusive; 23 or 25 hours after `startMs` on daylight-saving change days.
    let endMs: Int64

    var windowStartMs: Int64 { startMs - SessionDayPlanner.contextMarginMs }
    var windowEndMs: Int64 { endMs + SessionDayPlanner.contextMarginMs }

    func owns(_ session: ActivitySession) -> Bool { session.startMs >= startMs && session.startMs < endMs }
  }

  static func day(containing timeMs: Int64, calendar: Calendar) -> Day {
    let date = Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000)
    let start = calendar.startOfDay(for: date)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return Day(startMs: Int64((start.timeIntervalSince1970 * 1000).rounded()),
               endMs: Int64((end.timeIntervalSince1970 * 1000).rounded()))
  }

  /// Days overlapping `[fromMs, toMs]`, oldest first.
  static func days(from fromMs: Int64, to toMs: Int64, calendar: Calendar) -> [Day] {
    guard toMs >= fromMs else { return [] }
    var days: [Day] = []
    var day = day(containing: fromMs, calendar: calendar)
    while day.startMs <= toMs {
      days.append(day)
      guard day.endMs > day.startMs else { break }
      day = Self.day(containing: day.endMs, calendar: calendar)
    }
    return days
  }

  /// Distinct days containing the given times, oldest first.
  static func days(containing times: [Int64], calendar: Calendar) -> [Day] {
    var seen: Set<Int64> = []
    var days: [Day] = []
    for time in times.sorted() {
      if let last = days.last, time >= last.startMs, time < last.endMs { continue }
      let day = day(containing: time, calendar: calendar)
      if seen.insert(day.startMs).inserted { days.append(day) }
    }
    return days
  }

  /// Joins per-day results into one ordered list. Neighbouring days are segmented separately, so near
  /// midnight a session can overlap the next day's first one; the earlier session is then cut short.
  static func combine(_ sessions: [ActivitySession]) -> [ActivitySession] {
    let sorted = sessions.sorted { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.id < $1.id }
    var combined: [ActivitySession] = []
    combined.reserveCapacity(sorted.count)
    for session in sorted {
      if let last = combined.last {
        if last.id == session.id { continue }
        if last.endMs >= session.startMs {
          combined[combined.count - 1] = ActivitySession(id: last.id, startMs: last.startMs,
                                                         endMs: max(last.startMs, session.startMs - 1),
                                                         snapshotCount: last.snapshotCount, apps: last.apps,
                                                         keywords: last.keywords)
        }
      }
      combined.append(session)
    }
    return combined
  }
}
