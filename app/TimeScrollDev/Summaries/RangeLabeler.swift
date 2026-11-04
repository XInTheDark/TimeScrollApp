import Foundation

/// Local time labels for the model's input. These aren't shown in the UI.
struct RangeLabeler {
  private let formatter: DateFormatter
  private let dayFormatter: DateFormatter

  init(calendar: Calendar, range: ResolvedSummaryRange) {
    let singleDay = SessionDayPlanner.day(containing: range.fromMs, calendar: calendar).endMs >= range.toMs
    formatter = Self.makeFormatter(calendar: calendar, format: singleDay ? "HH:mm" : "EEE d MMM HH:mm")
    dayFormatter = Self.makeFormatter(calendar: calendar, format: "EEE d MMM yyyy")
  }

  func time(_ timeMs: Int64) -> String {
    formatter.string(from: Self.date(timeMs))
  }

  /// `[fromMs, toMs)`, as dates and times a reader would expect.
  func period(fromMs: Int64, toMs: Int64) -> String {
    let from = dayFormatter.string(from: Self.date(fromMs))
    let lastDay = dayFormatter.string(from: Self.date(max(fromMs, toMs - 1)))
    return from == lastDay ? from : "\(from) to \(lastDay)"
  }

  private static func date(_ timeMs: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000)
  }

  private static func makeFormatter(calendar: Calendar, format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter
  }
}
