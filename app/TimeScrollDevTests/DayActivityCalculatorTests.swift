import Foundation
import Testing
@testable import TimeScroll

struct DayActivityCalculatorTests {
  private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  private func ms(_ iso: String) -> Int64 {
    Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
  }

  private func day(_ iso: String) -> Date { calendar.startOfDay(for: ISO8601DateFormatter().date(from: iso)!) }

  @Test func screen_gaps_are_capped_and_counted_in_time_not_snapshots() {
    let rows = [
      CaptureInterval(startMs: ms("2026-10-01T10:00:00Z"), endMs: nil, isAudio: false),
      CaptureInterval(startMs: ms("2026-10-01T10:01:00Z"), endMs: nil, isAudio: false),
      CaptureInterval(startMs: ms("2026-10-01T11:00:00Z"), endMs: nil, isAudio: false),
    ]
    let result = DayActivityCalculator.activity(intervals: rows, calendar: calendar)
    let activity = result[day("2026-10-01T00:00:00Z")]
    #expect(activity?.snapshotCount == 3)
    // 1 minute until the second snapshot, then the 59 minute gap is capped at 5 minutes.
    #expect(activity?.coveredMs == Int64(6 * 60 * 1000))
  }

  @Test func audio_overlapping_screen_is_counted_once() {
    let rows = [
      CaptureInterval(startMs: ms("2026-10-01T10:00:00Z"), endMs: ms("2026-10-01T10:30:00Z"), isAudio: true),
      CaptureInterval(startMs: ms("2026-10-01T10:00:00Z"), endMs: nil, isAudio: false),
      CaptureInterval(startMs: ms("2026-10-01T10:04:00Z"), endMs: nil, isAudio: false),
    ]
    let result = DayActivityCalculator.activity(intervals: rows, calendar: calendar)
    #expect(result[day("2026-10-01T00:00:00Z")]?.coveredMs == Int64(30 * 60 * 1000))
  }

  @Test func time_is_split_at_midnight() {
    let rows = [
      CaptureInterval(startMs: ms("2026-10-01T23:30:00Z"), endMs: ms("2026-10-02T00:30:00Z"), isAudio: true),
    ]
    let result = DayActivityCalculator.activity(intervals: rows, calendar: calendar)
    #expect(result[day("2026-10-01T00:00:00Z")]?.coveredMs == Int64(30 * 60 * 1000))
    #expect(result[day("2026-10-02T00:00:00Z")]?.coveredMs == Int64(30 * 60 * 1000))
    #expect(result[day("2026-10-02T00:00:00Z")]?.snapshotCount == 0)
  }
}
