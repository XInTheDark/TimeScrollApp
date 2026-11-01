import Foundation
import Testing
@testable import TimeScroll

struct SessionDayPlannerTests {
  private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }

  private func ms(_ iso: String) -> Int64 {
    Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
  }

  private func session(_ id: Int64, _ start: Int64, _ end: Int64) -> ActivitySession {
    ActivitySession(id: id, startMs: start, endMs: end, snapshotCount: 1, apps: [], keywords: [])
  }

  @Test func dayIsLocalMidnightToMidnight() {
    let day = SessionDayPlanner.day(containing: ms("2026-10-01T10:00:00Z"), calendar: calendar("UTC"))
    #expect(day.startMs == ms("2026-10-01T00:00:00Z"))
    #expect(day.endMs == ms("2026-10-02T00:00:00Z"))
    #expect(day.windowStartMs == ms("2026-09-30T21:00:00Z"))
    #expect(day.windowEndMs == ms("2026-10-02T03:00:00Z"))
  }

  @Test func midnightBelongsToTheNewDay() {
    let day = SessionDayPlanner.day(containing: ms("2026-10-02T00:00:00Z"), calendar: calendar("UTC"))
    #expect(day.startMs == ms("2026-10-02T00:00:00Z"))
  }

  @Test func daylightSavingDaysAre23And25Hours() {
    let berlin = calendar("Europe/Berlin")
    let spring = SessionDayPlanner.day(containing: ms("2026-03-29T12:00:00Z"), calendar: berlin)
    #expect(spring.endMs - spring.startMs == Int64(23 * 3_600_000))
    let autumn = SessionDayPlanner.day(containing: ms("2026-10-25T12:00:00Z"), calendar: berlin)
    #expect(autumn.endMs - autumn.startMs == Int64(25 * 3_600_000))
  }

  @Test func rangeCoversEveryOverlappingDay() {
    let days = SessionDayPlanner.days(from: ms("2026-10-01T23:00:00Z"), to: ms("2026-10-03T01:00:00Z"), calendar: calendar("UTC"))
    #expect(days.map(\.startMs) == [ms("2026-10-01T00:00:00Z"), ms("2026-10-02T00:00:00Z"), ms("2026-10-03T00:00:00Z")])
    #expect(SessionDayPlanner.days(from: 10, to: 5, calendar: calendar("UTC")).isEmpty)
  }

  @Test func daysContainingTimesAreDistinctAndSorted() {
    let times = [ms("2026-10-03T05:00:00Z"), ms("2026-10-01T05:00:00Z"), ms("2026-10-01T23:00:00Z"), ms("2026-10-03T06:00:00Z")]
    let days = SessionDayPlanner.days(containing: times, calendar: calendar("UTC"))
    #expect(days.map(\.startMs) == [ms("2026-10-01T00:00:00Z"), ms("2026-10-03T00:00:00Z")])
    #expect(SessionDayPlanner.days(containing: [], calendar: calendar("UTC")).isEmpty)
  }

  @Test func dayOwnsSessionsStartingWithinIt() {
    let day = SessionDayPlanner.day(containing: ms("2026-10-01T10:00:00Z"), calendar: calendar("UTC"))
    #expect(day.owns(session(1, ms("2026-10-01T23:30:00Z"), ms("2026-10-02T00:30:00Z"))))
    #expect(!day.owns(session(2, ms("2026-09-30T23:30:00Z"), ms("2026-10-01T00:30:00Z"))))
    #expect(!day.owns(session(3, day.endMs, day.endMs + 1)))
  }

  @Test func combineSortsDropsDuplicatesAndTrimsOverlaps() {
    let combined = SessionDayPlanner.combine([session(3, 300, 400), session(1, 100, 250), session(2, 200, 280), session(1, 100, 250)])
    #expect(combined.map(\.id) == [1, 2, 3])
    #expect(combined[0].endMs == 199)
    #expect(combined[1].endMs == 280)
    #expect(SessionDayPlanner.combine([]).isEmpty)
  }
}
