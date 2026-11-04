import Foundation
import Testing
@testable import TimeScroll

struct SummaryRangeResolverTests {
  private let utc = SummaryTestTime.calendar()
  private let hour: Int64 = 3_600_000
  private var day: Int64 { 24 * hour }
  private let start = SummaryTestTime.ms(2026, 1, 15)
  private let farFuture = SummaryTestTime.ms(2030, 1, 1)

  private func resolve(_ from: Int64, _ to: Int64) -> ResolvedSummaryRange {
    SummaryRangeResolver.resolve(fromMs: from, toMs: to, calendar: utc)
  }

  @Test func emptyAndInvertedRangesAreEmpty() {
    #expect(resolve(start, start).isEmpty)
    #expect(resolve(start, start - 1).isEmpty)
    #expect(SummaryRangeResolver.pieces(for: resolve(start, start), nowMs: farFuture, calendar: utc).isEmpty)
  }

  @Test func shortRangesAreExact() {
    let range = resolve(start + 123, start + 6 * hour + 123)
    #expect(range == ResolvedSummaryRange(fromMs: start + 123, toMs: start + 6 * hour + 123, precision: .exact))
    #expect(SummaryRangeResolver.pieces(for: range, nowMs: farFuture, calendar: utc) == [.captures(fromMs: range.fromMs, toMs: range.toMs)])
  }

  @Test func justPastSixHoursSnapsToQuarterHours() {
    let range = resolve(start + 1, start + 6 * hour + 2)
    #expect(range == ResolvedSummaryRange(fromMs: start, toMs: start + 6 * hour + AppTimeRollup.quarterHourMs, precision: .quarterHour))
  }

  @Test func fourteenDaysIsTheQuarterHourLimit() {
    #expect(resolve(start, start + 14 * day).precision == .quarterHour)
    let longer = resolve(start + hour, start + 14 * day + hour + 1)
    #expect(longer.precision == .day)
    #expect(longer.fromMs == start)
    #expect(longer.toMs == start + 15 * day)
  }

  @Test func partialDaysUseQuarterHoursAndWholeDaysUseDayRows() {
    let range = resolve(start + 22 * hour, start + 2 * day + 2 * hour)
    let days = SessionDayPlanner.days(from: range.fromMs, to: range.toMs - 1, calendar: utc)
    #expect(SummaryRangeResolver.pieces(for: range, nowMs: farFuture, calendar: utc) == [
      .quarterHours(day: days[0], fromMs: range.fromMs, toMs: start + day),
      .wholeDay(days[1]),
      .quarterHours(day: days[2], fromMs: start + 2 * day, toMs: range.toMs),
    ])
  }

  @Test func seriesCanSplitWholeDays() {
    let range = resolve(start, start + day)
    let oneDay = SessionDayPlanner.day(containing: start, calendar: utc)
    #expect(SummaryRangeResolver.pieces(for: range, nowMs: farFuture, calendar: utc) == [.wholeDay(oneDay)])
    #expect(SummaryRangeResolver.pieces(for: range, nowMs: farFuture, calendar: utc, splitWholeDays: true) == [
      .quarterHours(day: oneDay, fromMs: start, toMs: start + day),
    ])
  }

  @Test func unsettledDaysReadCaptures() {
    let range = resolve(start, start + 2 * day)
    let first = SessionDayPlanner.day(containing: start, calendar: utc)
    // Ten minutes after the second day ended it counts as settled; a moment before, it doesn't.
    let settleDelay = ActivitySessionProvider.settleDelayMs
    #expect(SummaryRangeResolver.pieces(for: range, nowMs: start + 2 * day + settleDelay - 1, calendar: utc) == [
      .wholeDay(first), .captures(fromMs: start + day, toMs: start + 2 * day),
    ])
    #expect(SummaryRangeResolver.pieces(for: range, nowMs: start + 2 * day + settleDelay, calendar: utc).allSatisfy { $0.day != nil })
  }

  @Test func dstDaysKeepTheirRealLength() {
    let zone = "America/New_York"
    let calendar = SummaryTestTime.calendar(zone)
    let springStart = SummaryTestTime.ms(2026, 3, 8, zone: zone)
    let springDay = SessionDayPlanner.day(containing: springStart + hour, calendar: calendar)
    #expect(springDay.endMs - springDay.startMs == 23 * hour)
    let fallStart = SummaryTestTime.ms(2026, 11, 1, zone: zone)
    let fallDay = SessionDayPlanner.day(containing: fallStart + hour, calendar: calendar)
    #expect(fallDay.endMs - fallDay.startMs == 25 * hour)

    let range = SummaryRangeResolver.resolve(fromMs: fallDay.startMs, toMs: fallDay.endMs, calendar: calendar)
    #expect(range.fromMs == fallDay.startMs && range.toMs == fallDay.endMs)
    #expect(SummaryRangeResolver.pieces(for: range, nowMs: farFuture, calendar: calendar) == [.wholeDay(fallDay)])
  }

  @Test func localMidnightsLandOnQuarterHoursInOffsetZones() {
    for zone in ["Asia/Kathmandu", "Asia/Kolkata", "Australia/Lord_Howe", "Pacific/Chatham", "America/St_Johns"] {
      let midnight = SummaryTestTime.ms(2026, 6, 1, zone: zone)
      #expect(AppTimeRollup.floor(midnight, to: AppTimeRollup.quarterHourMs) == midnight, "\(zone)")
    }
  }
}
