import Foundation

/// Text for ranges and durations shown in the selection UI.
enum TimelineRangeFormat {
  /// "2h 05m", "45m", "30s".
  static func duration(_ ms: Int64) -> String {
    let seconds = max(0, ms) / 1000
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours >= 24 {
      let days = hours / 24
      return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }
    if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
    if minutes > 0 { return "\(minutes)m" }
    return "\(seconds)s"
  }

  /// A finished day or week reads as its dates alone; other ranges include their times.
  static func period(_ range: TimelineRange, calendar: Calendar = .current, locale: Locale = .current) -> String {
    let formatter = DateIntervalFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = locale
    let from = Date(timeIntervalSince1970: TimeInterval(range.fromMs) / 1000)
    let to = Date(timeIntervalSince1970: TimeInterval(range.toMs) / 1000)
    let startsAtMidnight = calendar.startOfDay(for: from) == from
    let endsAtMidnight = calendar.startOfDay(for: to) == to
    if startsAtMidnight, endsAtMidnight {
      formatter.dateTemplate = "EEEdMMM"
      return formatter.string(from: from, to: to.addingTimeInterval(-1))
    }
    formatter.dateTemplate = "EEEdMMMjm"
    return formatter.string(from: from, to: to)
  }

  static func counts(_ count: DB.SnapshotRangeCount) -> String {
    var parts: [String] = []
    if count.screen > 0 || count.audio == 0 {
      parts.append("\(count.screen.formatted()) \(count.screen == 1 ? "snapshot" : "snapshots")")
    }
    if count.audio > 0 {
      parts.append("\(count.audio.formatted()) audio \(count.audio == 1 ? "clip" : "clips")")
    }
    return parts.joined(separator: " and ")
  }
}
