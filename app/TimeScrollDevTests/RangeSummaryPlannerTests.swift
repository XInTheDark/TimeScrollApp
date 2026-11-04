import Foundation
import Testing
@testable import TimeScroll

struct RangeSummaryPlannerTests {
  private let day: Int64 = 86_400_000
  private let utc = SummaryTestTime.calendar()
  // A Monday, with weeks starting on Monday in the test calendar.
  private let monday = SummaryTestTime.ms(2026, 1, 12)
  private let farFuture = SummaryTestTime.ms(2030, 1, 1)

  private func summary(_ from: Int64, _ to: Int64) -> StoredRangeSummary {
    StoredRangeSummary(startMs: from, endMs: to, model: "m", promptVersion: 1, text: "t", createdAtMs: 0)
  }

  @Test func nothingStoredIsOneGap() {
    let plan = RangeSummaryPlanner.plan(fromMs: 0, toMs: 100, stored: [])
    #expect(plan.reused.isEmpty)
    #expect(plan.gaps == [0..<100])
  }

  @Test func storedPiecesLeaveGapsBetweenThem() {
    let plan = RangeSummaryPlanner.plan(fromMs: 0, toMs: 100, stored: [summary(40, 60), summary(10, 20)])
    #expect(plan.reused.map(\.startMs) == [10, 40])
    #expect(plan.gaps == [0..<10, 20..<40, 60..<100])
  }

  @Test func weeksWinOverTheDaysInsideThem() {
    let week = summary(monday, monday + 7 * day)
    let tuesday = summary(monday + day, monday + 2 * day)
    let nextDay = summary(monday + 7 * day, monday + 8 * day)
    let plan = RangeSummaryPlanner.plan(fromMs: monday, toMs: monday + 8 * day, stored: [tuesday, nextDay, week])
    #expect(plan.reused == [week, nextDay])
    #expect(plan.gaps.isEmpty)
  }

  @Test func aSummaryOfExactlyThisRangeIsNotReused() {
    let plan = RangeSummaryPlanner.plan(fromMs: 0, toMs: 100, stored: [summary(0, 100)])
    #expect(plan.reused.isEmpty)
    #expect(plan.gaps == [0..<100])
  }

  @Test func storedOutsideTheRangeIsIgnored() {
    let plan = RangeSummaryPlanner.plan(fromMs: 50, toMs: 100, stored: [summary(0, 60), summary(90, 110)])
    #expect(plan.reused.isEmpty)
  }

  @Test func onlySettledDaysAndWeeksAreStorable() {
    func storable(_ from: Int64, _ to: Int64, now: Int64? = nil, calendar: Calendar? = nil) -> Bool {
      RangeSummaryPlanner.isStorable(fromMs: from, toMs: to, nowMs: now ?? farFuture, calendar: calendar ?? utc)
    }
    #expect(storable(monday, monday + day))
    #expect(storable(monday, monday + 7 * day))
    #expect(!storable(monday + day, monday + 8 * day))   // seven days, not a calendar week
    #expect(!storable(monday, monday + 2 * day))
    #expect(!storable(monday + 1, monday + day))
    #expect(!storable(monday, monday))
    #expect(!storable(monday, monday + day, now: monday + day))   // only just ended
    #expect(storable(monday, monday + day, now: monday + day + ActivitySessionProvider.settleDelayMs))
  }

  @Test func monthsAndYearsAreStorable() {
    let storable = { (from: Int64, to: Int64) in RangeSummaryPlanner.isStorable(fromMs: from, toMs: to, nowMs: farFuture, calendar: utc) }
    #expect(storable(SummaryTestTime.ms(2026, 2, 1), SummaryTestTime.ms(2026, 3, 1)))
    #expect(storable(SummaryTestTime.ms(2026, 1, 1), SummaryTestTime.ms(2027, 1, 1)))
    #expect(!storable(SummaryTestTime.ms(2026, 2, 2), SummaryTestTime.ms(2026, 3, 2)))
  }

  @Test func dstDayAndWeekAreStorable() {
    let zone = "America/New_York"
    let calendar = SummaryTestTime.calendar(zone)
    let sunday = SummaryTestTime.ms(2026, 3, 8, zone: zone)
    #expect(RangeSummaryPlanner.isStorable(fromMs: sunday, toMs: SummaryTestTime.ms(2026, 3, 9, zone: zone), nowMs: farFuture, calendar: calendar))
    let weekStart = SummaryTestTime.ms(2026, 3, 2, zone: zone)
    #expect(RangeSummaryPlanner.isStorable(fromMs: weekStart, toMs: SummaryTestTime.ms(2026, 3, 9, zone: zone), nowMs: farFuture, calendar: calendar))
  }
}
