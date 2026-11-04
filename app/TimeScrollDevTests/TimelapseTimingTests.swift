import Foundation
import Testing
@testable import TimeScroll

struct TimelapseTimingTests {
  @Test func proportionalIntervalsUseOneScaleAcrossSessions() {
    var timing = TimelapseTiming(sessions: [0...60_000, 300_000...480_000], matchRealTime: true, speed: 60)
    timing.advance(from: 0, to: 10_000)
    #expect(abs(timing.seconds - 1.0 / 6) < 0.00001)
    timing.advance(from: 10_000, to: 60_000)
    #expect(abs(timing.seconds - 1) < 0.00001)
    timing.advance(from: 60_000, to: 300_000)
    #expect(abs(timing.seconds - (1 + 1.0 / 600)) < 0.00001)
    timing.advance(from: 300_000, to: 480_000)
    #expect(abs(timing.seconds - (4 + 1.0 / 600)) < 0.00001)
  }

  @Test func equalFramesIgnoreIntervalsAndSessionGaps() {
    var timing = TimelapseTiming(sessions: [], matchRealTime: false, speed: 60)
    for next: Int64? in [1000, 8_000_000, nil] { timing.advance(from: 0, to: next) }
    #expect(abs(timing.seconds - 0.1) < 0.00001)
  }

  @Test func singleAndSimultaneousFramesHavePositiveDuration() {
    var timing = TimelapseTiming(sessions: [1000...1000], matchRealTime: true, speed: 60)
    timing.advance(from: 1000, to: 1000)
    #expect(timing.seconds > 0)
    timing.advance(from: 1000, to: nil)
    #expect(timing.seconds > 1.0 / 30)
  }

  @Test func rangeClippingAndMidnightAreAbsoluteTimeBased() {
    let midnight: Int64 = 1_798_761_600_000
    var timing = TimelapseTiming(sessions: [(midnight - 100_000)...(midnight + 100_000)], matchRealTime: true, speed: 10)
    timing.advance(from: midnight - 1000, to: midnight + 1000)
    #expect(abs(timing.seconds - 0.2) < 0.00001)
  }

  @Test func stoppedRecordingGapsAreRemovedButUnchangedScreenTimeIsKept() {
    var timing = TimelapseTiming(sessions: [0...120_000, 600_000...900_000], matchRealTime: true, speed: 60)
    timing.advance(from: 0, to: 60_000)
    #expect(timing.seconds == 1)
    timing.advance(from: 60_000, to: 660_000)
    #expect(timing.seconds == 3) // 1 min before stopping + 1 min after resuming, excluding the pause.
    timing.advance(from: 660_000, to: nil)
    #expect(timing.seconds == 7) // Hold the final snapshot until recording/range end.
  }

  @Test func oldHistoryWithoutSessionMetadataRetainsObservedTiming() {
    var timing = TimelapseTiming(sessions: [], matchRealTime: true, speed: 60)
    timing.advance(from: 0, to: 120_000)
    #expect(timing.seconds == 2)
  }

  @Test func longHistoryAdvancesWithoutAccumulatingGapTime() {
    let sessions = (0..<100_000).map { Int64($0) * 100_000...Int64($0) * 100_000 + 1000 }
    var timing = TimelapseTiming(sessions: sessions, matchRealTime: true, speed: 1)
    for index in 0..<100_000 {
      let time = Int64(index) * 100_000
      timing.advance(from: time, to: time + 1000)
      if index < 99_999 { timing.advance(from: time + 1000, to: time + 100_000) }
    }
    #expect(abs(timing.seconds - (100_000 + Double(99_999) / 600)) < 0.001)
  }
}
