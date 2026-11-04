#if DEBUG
import Foundation

/// Turns the manifest's working days into capture times. Pure, so it can be tested.
enum DemoSchedule {
  struct Capture: Equatable {
    let timeMs: Int64
    let screen: String
  }

  static func captures(days: [[DemoManifest.Block]],
                       today: [DemoManifest.Block],
                       historyDays: Int,
                       intervalSeconds: Int,
                       now: Date,
                       calendar: Calendar) -> [Capture] {
    guard intervalSeconds > 0 else { return [] }
    var captures: [Capture] = []
    var workday = 0
    let startOfToday = calendar.startOfDay(for: now)
    if !days.isEmpty, historyDays > 0 {
      for back in stride(from: historyDays, through: 1, by: -1) {
        guard let day = calendar.date(byAdding: .day, value: -back, to: startOfToday),
              !calendar.isDateInWeekend(day) else { continue }
        for block in days[workday % days.count] {
          guard let start = startTime(of: block, on: day, calendar: calendar) else { continue }
          captures += blockCaptures(block, from: start, intervalSeconds: intervalSeconds)
        }
        workday += 1
      }
    }
    return captures + todayCaptures(today, endingAt: now, intervalSeconds: intervalSeconds)
  }

  /// Today's blocks run back to back and end now, so nothing is ever in the future.
  private static func todayCaptures(_ blocks: [DemoManifest.Block], endingAt now: Date, intervalSeconds: Int) -> [Capture] {
    let totalMinutes = blocks.reduce(0) { $0 + $1.minutes }
    var start = now.addingTimeInterval(-Double(totalMinutes * 60))
    var captures: [Capture] = []
    for block in blocks {
      captures += blockCaptures(block, from: start, intervalSeconds: intervalSeconds)
      start = start.addingTimeInterval(Double(block.minutes * 60))
    }
    return captures
  }

  private static func blockCaptures(_ block: DemoManifest.Block, from start: Date, intervalSeconds: Int) -> [Capture] {
    let startMs = Int64(start.timeIntervalSince1970 * 1000)
    return stride(from: 0, to: block.minutes * 60, by: intervalSeconds).map {
      Capture(timeMs: startMs + Int64($0) * 1000, screen: block.screen)
    }
  }

  private static func startTime(of block: DemoManifest.Block, on day: Date, calendar: Calendar) -> Date? {
    let parts = block.start.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
  }
}
#endif
