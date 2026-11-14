import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpHeaderTextTests {
  private let locale = Locale(identifier: "en_US")
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func ms(_ string: String) -> Int64 {
    Int64(ISO8601DateFormatter().date(from: string)!.timeIntervalSince1970 * 1000)
  }

  @Test func aBlockShowsItsPeriod() {
    let range = TimelineRange(fromMs: ms("2026-11-14T09:00:00Z"), toMs: ms("2026-11-14T10:00:00Z"))!
    #expect(TimeWarpHeaderText.heading(target: .range(range), range: range, calendar: calendar, locale: locale)
            == TimelineRangeFormat.period(range, calendar: calendar, locale: locale))
  }

  @Test func aMomentShowsItsDateAndTime() {
    let moment = ms("2026-11-14T15:42:00Z")
    let range = TimeWarpLookback.hour.range(endingAt: moment, sessionStartMs: nil, calendar: calendar)
    let heading = TimeWarpHeaderText.heading(target: .moment(moment), range: range, calendar: calendar, locale: locale)
    #expect(heading.contains("Nov"))
    #expect(heading.contains("14"))
    #expect(heading.contains("3:42"))
  }

  @Test func summaryOnTheSameDayShowsOnlyTheTime() {
    let moment = ms("2026-11-14T15:42:00Z")
    let range = TimelineRange.covering(ms("2026-11-14T14:10:00Z"), moment)
    let summary = TimeWarpHeaderText.lookbackSummary(range: range, momentMs: moment, calendar: calendar, locale: locale)
    #expect(summary.hasPrefix("From 2:10"))
    #expect(summary.hasSuffix("· 1h 32m"))
    #expect(!summary.contains("Nov"))
  }

  @Test func summaryFromTheDayBeforeShowsTheDate() {
    let moment = ms("2026-11-14T00:30:00Z")
    let range = TimelineRange.covering(ms("2026-11-13T23:00:00Z"), moment)
    let summary = TimeWarpHeaderText.lookbackSummary(range: range, momentMs: moment, calendar: calendar, locale: locale)
    #expect(summary.contains("Nov"))
    #expect(summary.contains("13"))
    #expect(summary.hasSuffix("· 1h 30m"))
  }
}
