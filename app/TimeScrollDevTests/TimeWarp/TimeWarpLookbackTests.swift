import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpLookbackTests {
  private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }

  private func ms(_ string: String) -> Int64 {
    Int64(ISO8601DateFormatter().date(from: string)!.timeIntervalSince1970 * 1000)
  }

  private let moment: Int64 = 1_800_000_000_500

  @Test func fixedLookbacksEndAtTheMomentsSecond() {
    let fifteen = TimeWarpLookback.fifteenMinutes.range(endingAt: moment, sessionStartMs: nil)
    #expect(fifteen.fromMs == moment - 500 - 15 * 60_000)
    #expect(fifteen.toMs == moment - 500 + 1000)
    let hour = TimeWarpLookback.hour.range(endingAt: moment, sessionStartMs: 123)
    #expect(hour.fromMs == moment - 500 - 60 * 60_000)
  }

  @Test func sessionStartsAtTheSession() {
    let range = TimeWarpLookback.session.range(endingAt: moment, sessionStartMs: moment - 42 * 60_000 - 500)
    #expect(range.fromMs == moment - 500 - 42 * 60_000)
    #expect(range.toMs == moment - 500 + 1000)
  }

  @Test func sessionWithoutASessionFallsBackToAnHour() {
    #expect(TimeWarpLookback.session.effective(sessionStartMs: nil) == .hour)
    #expect(TimeWarpLookback.session.effective(sessionStartMs: 1) == .session)
    #expect(TimeWarpLookback.today.effective(sessionStartMs: nil) == .today)
    #expect(TimeWarpLookback.session.range(endingAt: moment, sessionStartMs: nil)
            == TimeWarpLookback.hour.range(endingAt: moment, sessionStartMs: nil))
  }

  @Test func aSessionStartAfterTheMomentStillGivesAValidBlock() {
    let range = TimeWarpLookback.session.range(endingAt: moment, sessionStartMs: moment + 60_000)
    #expect(range.fromMs <= moment && moment < range.toMs)
  }

  @Test func todayStartsAtLocalMidnight() {
    let cal = calendar("Asia/Singapore")
    let at = ms("2026-11-14T07:42:10Z") // 15:42 in Singapore
    let range = TimeWarpLookback.today.range(endingAt: at, sessionStartMs: nil, calendar: cal)
    #expect(range.fromMs == ms("2026-11-13T16:00:00Z"))
  }

  @Test func todayAtMidnightIsStillABlock() {
    let cal = calendar("Asia/Singapore")
    let midnight = ms("2026-11-13T16:00:00Z")
    let range = TimeWarpLookback.today.range(endingAt: midnight, sessionStartMs: nil, calendar: cal)
    #expect(range.fromMs == midnight)
    #expect(range.toMs == midnight + 1000)
  }

  @Test func todayOnADSTChangeStartsAtThatDaysMidnight() {
    let cal = calendar("America/New_York")
    // Clocks went forward at 2 AM on 8 March 2026; midnight was still EST (UTC-5).
    let range = TimeWarpLookback.today.range(endingAt: ms("2026-03-08T15:00:00Z"), sessionStartMs: nil, calendar: cal)
    #expect(range.fromMs == ms("2026-03-08T05:00:00Z"))
  }

  @Test func longerStepsUpAndStops() {
    #expect(TimeWarpLookback.fifteenMinutes.longer == .hour)
    #expect(TimeWarpLookback.hour.longer == .session)
    #expect(TimeWarpLookback.session.longer == .today)
    #expect(TimeWarpLookback.today.longer == nil)
  }
}
