#if DEBUG
import Foundation
import Testing
@testable import TimeScroll

struct DemoScheduleTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func block(_ start: String, _ minutes: Int, _ screen: String) -> DemoManifest.Block {
    DemoManifest.Block(start: start, minutes: minutes, screen: screen)
  }

  private func captures(days: [[DemoManifest.Block]] = [], today: [DemoManifest.Block] = [], historyDays: Int = 0,
                        interval: Int = 60, now: Date) -> [DemoSchedule.Capture] {
    DemoSchedule.captures(days: days, today: today, historyDays: historyDays, intervalSeconds: interval, now: now, calendar: calendar)
  }

  @Test func emptyManifestHasNoCaptures() {
    #expect(captures(now: date(2026, 11, 4, 12)).isEmpty)
  }

  @Test func zeroIntervalHasNoCaptures() {
    #expect(captures(today: [block("09:00", 10, "a")], interval: 0, now: date(2026, 11, 4, 12)).isEmpty)
  }

  @Test func todayEndsBeforeNowAndRunsBackToBack() {
    let now = date(2026, 11, 4, 12)
    let result = captures(today: [block("00:00", 2, "a"), block("00:00", 1, "b")], now: now)
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    #expect(result.map(\.screen) == ["a", "a", "b"])
    #expect(result.map(\.timeMs) == [nowMs - 180_000, nowMs - 120_000, nowMs - 60_000])
  }

  @Test func historySkipsWeekendsAndStaysBeforeToday() {
    // Wednesday, looking back over Saturday and Sunday.
    let now = date(2026, 11, 4, 12)
    let result = captures(days: [[block("09:00", 1, "a")]], historyDays: 7, now: now)
    let days = result.map { Date(timeIntervalSince1970: Double($0.timeMs) / 1000) }
    #expect(days.count == 5)
    #expect(days.allSatisfy { !calendar.isDateInWeekend($0) && $0 < calendar.startOfDay(for: now) })
  }

  @Test func historyCyclesThroughTheWorkingDaysOldestFirst() {
    // Monday to Wednesday of one week, seen from Thursday.
    let result = captures(days: [[block("09:00", 1, "a")], [block("09:00", 1, "b")]], historyDays: 3, now: date(2026, 11, 5, 12))
    #expect(result.map(\.screen) == ["a", "b", "a"])
  }

  @Test func historyStartTimesKeepLocalTimeAcrossDST() {
    // UK clocks went back on Sunday, October 25, 2026.
    // Thursday and Friday before the change, Monday and Tuesday after it.
    let result = captures(days: [[block("09:00", 1, "a")]], historyDays: 6, now: date(2026, 10, 28, 12))
    let hours = result.map { calendar.component(.hour, from: Date(timeIntervalSince1970: Double($0.timeMs) / 1000)) }
    #expect(hours == [9, 9, 9, 9])
  }

  @Test func malformedStartTimeIsSkipped() {
    #expect(captures(days: [[block("nine", 1, "a")]], historyDays: 3, now: date(2026, 11, 5, 12)).isEmpty)
  }

  @Test func blockCapturesFollowTheInterval() {
    let result = captures(today: [block("00:00", 2, "a")], interval: 45, now: date(2026, 11, 4, 12))
    #expect(result.count == 3)
    #expect(result[1].timeMs - result[0].timeMs == Int64(45_000))
  }
}
#endif
