import Foundation

/// Common ranges. Finished days and weeks are also the ones whose summaries are saved.
enum TimelineRangePreset: String, CaseIterable, Identifiable {
  case today = "Today"
  case yesterday = "Yesterday"
  case thisWeek = "This Week"
  case lastWeek = "Last Week"

  var id: Self { self }

  func range(now: Date, calendar: Calendar) -> TimelineRange? {
    let today = calendar.startOfDay(for: now)
    func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    switch self {
    case .today:
      return TimelineRange.covering(ms(today), ms(now))
    case .yesterday:
      guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
      return TimelineRange(fromMs: ms(start), toMs: ms(today))
    case .thisWeek:
      guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
      return TimelineRange.covering(ms(week.start), ms(now))
    case .lastWeek:
      guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start) else { return nil }
      return TimelineRange(fromMs: ms(start), toMs: ms(thisWeek.start))
    }
  }
}
