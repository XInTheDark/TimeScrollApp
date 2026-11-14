import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpRecencyTests {
  private let halfLife = TimeWarpRecency.halfLifeMs

  @Test func emptyOrAfterTheMomentCountsNothing() {
    #expect(TimeWarpRecency.weightedMs(startMs: 100, endMs: 100, momentMs: 1_000) == 0)
    #expect(TimeWarpRecency.weightedMs(startMs: 200, endMs: 100, momentMs: 1_000) == 0)
    #expect(TimeWarpRecency.weightedMs(startMs: 2_000, endMs: 3_000, momentMs: 1_000) == 0)
  }

  @Test func timeAfterTheMomentIsIgnored() {
    let clipped = TimeWarpRecency.weightedMs(startMs: 0, endMs: 10_000_000, momentMs: 1_000_000)
    #expect(clipped == TimeWarpRecency.weightedMs(startMs: 0, endMs: 1_000_000, momentMs: 1_000_000))
  }

  @Test func oneHalfLifeRightBeforeTheMomentIsWorthItsAverage() {
    let moment: Int64 = 10_000_000
    let weighted = TimeWarpRecency.weightedMs(startMs: moment - Int64(halfLife), endMs: moment, momentMs: moment)
    #expect(abs(weighted - halfLife / (2 * M_LN2)) < 1)
  }

  @Test func nearerTimeOutweighsTheSameTimeEarlier() {
    let moment: Int64 = 10_000_000
    let near = TimeWarpRecency.weightedMs(startMs: moment - 60_000, endMs: moment, momentMs: moment)
    let far = TimeWarpRecency.weightedMs(startMs: moment - 3_660_000, endMs: moment - 3_600_000, momentMs: moment)
    #expect(near > far * 15)
  }

  @Test func hugeSpansStayFinite() {
    let weighted = TimeWarpRecency.weightedMs(startMs: 0, endMs: 1_800_000_000_000, momentMs: 1_800_000_000_000)
    #expect(weighted.isFinite)
    #expect(abs(weighted - halfLife / M_LN2) < 1)
  }
}
