#if DEBUG
import Foundation
import Testing
@testable import TimeScroll

struct DemoTimeWarpSpansTests {
  private func capture(_ seconds: Int64, _ screen: String) -> DemoSchedule.Capture {
    DemoSchedule.Capture(timeMs: seconds * 1000, screen: screen)
  }

  @Test func noCapturesMakeNoSpans() {
    #expect(DemoTimeWarpSpans.spans(of: [], intervalSeconds: 45).isEmpty)
  }

  @Test func oneCaptureLastsOneInterval() {
    let spans = DemoTimeWarpSpans.spans(of: [capture(100, "a")], intervalSeconds: 45)
    #expect(spans == [.init(screen: "a", startMs: 100_000, endMs: 145_000)])
  }

  @Test func runsOfOneScreenBecomeOneSpan() {
    let captures = [capture(0, "a"), capture(45, "a"), capture(90, "b"), capture(135, "b"), capture(180, "a")]
    let spans = DemoTimeWarpSpans.spans(of: captures, intervalSeconds: 45)
    #expect(spans == [
      .init(screen: "a", startMs: 0, endMs: 90_000),
      .init(screen: "b", startMs: 90_000, endMs: 180_000),
      .init(screen: "a", startMs: 180_000, endMs: 225_000),
    ])
  }

  @Test func aGapSplitsTheSameScreen() {
    let captures = [capture(0, "a"), capture(45, "a"), capture(3_600, "a")]
    let spans = DemoTimeWarpSpans.spans(of: captures, intervalSeconds: 45)
    #expect(spans == [
      .init(screen: "a", startMs: 0, endMs: 90_000),
      .init(screen: "a", startMs: 3_600_000, endMs: 3_645_000),
    ])
  }

  @Test func spansFromTheScheduleNeverOverlap() {
    let day: [DemoManifest.Block] = [.init(start: "09:00", minutes: 30, screen: "a"), .init(start: "09:30", minutes: 20, screen: "b")]
    let captures = DemoSchedule.captures(days: [day], today: day, historyDays: 7, intervalSeconds: 45,
                                         now: Date(timeIntervalSince1970: 1_794_000_000), calendar: Calendar(identifier: .gregorian))
    let spans = DemoTimeWarpSpans.spans(of: captures, intervalSeconds: 45)
    #expect(!spans.isEmpty)
    for (earlier, later) in zip(spans, spans.dropFirst()) { #expect(earlier.endMs <= later.startMs) }
  }
}
#endif
