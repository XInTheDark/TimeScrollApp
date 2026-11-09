import Foundation
import Testing
@testable import TimeScroll

struct AXAppSightingsTests {
  @Test func appSeenOnceHasNotSettled() {
    let sightings = AXAppSightings()
    #expect(sightings.record([1, 2], now: 100).isEmpty)
  }

  @Test func appSettlesWhenReadInConsecutiveCapturesSettleTimeApart() {
    let sightings = AXAppSightings()
    _ = sightings.record([1], now: 100)
    #expect(sightings.record([1], now: 102).isEmpty)
    #expect(sightings.record([1], now: 103) == [1])
    #expect(sightings.record([1], now: 500) == [1])
  }

  @Test func consecutiveCapturesFarApartSettleAtOnce() {
    // Frames are captured only when the screen changes, so captures can be minutes apart.
    let sightings = AXAppSightings()
    _ = sightings.record([1], now: 0)
    #expect(sightings.record([1], now: 120) == [1])
  }

  @Test func captureWithoutTheAppRestartsItsRun() {
    let sightings = AXAppSightings()
    _ = sightings.record([1], now: 0)
    _ = sightings.record([2], now: 5)
    #expect(sightings.record([1, 2], now: 10) == [2])
    #expect(sightings.record([1, 2], now: 13) == [1, 2])
  }

  @Test func emptyCaptureForgetsEveryApp() {
    let sightings = AXAppSightings()
    _ = sightings.record([1, 2], now: 0)
    _ = sightings.record([], now: 5)
    #expect(sightings.record([1, 2], now: 10).isEmpty)
  }

  @Test func manyAppsAreTrackedIndependently() {
    let sightings = AXAppSightings()
    let early = Set<pid_t>(1...500)
    let late = Set<pid_t>(501...1_000)
    _ = sightings.record(early, now: 0)
    _ = sightings.record(early.union(late), now: 2)
    #expect(sightings.record(early.union(late), now: 4) == early)
    #expect(sightings.record(early.union(late), now: 5) == early.union(late))
  }
}
