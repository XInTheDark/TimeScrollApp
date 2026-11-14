import Foundation

/// The text at the top of the Time Warp window. Pure, so it can be tested.
enum TimeWarpHeaderText {
  /// The block's dates and times, or the moment's.
  static func heading(target: TimeWarpTarget, range: TimelineRange, calendar: Calendar = .current, locale: Locale = .current) -> String {
    guard let moment = target.momentMs else { return TimelineRangeFormat.period(range, calendar: calendar, locale: locale) }
    return format(moment, template: "EEEdMMMjm", calendar: calendar, locale: locale)
  }

  /// Where a moment's look-back starts and how long it is: "From 2:10 PM · 1h 32m".
  static func lookbackSummary(range: TimelineRange, momentMs: Int64, calendar: Calendar = .current, locale: Locale = .current) -> String {
    let sameDay = calendar.isDate(date(range.fromMs), inSameDayAs: date(momentMs))
    let start = format(range.fromMs, template: sameDay ? "jm" : "EEEdMMMjm", calendar: calendar, locale: locale)
    return "From \(start) · \(TimelineRangeFormat.duration(max(0, momentMs - range.fromMs)))"
  }

  private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

  private static func format(_ ms: Int64, template: String, calendar: Calendar, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date(ms))
  }
}
