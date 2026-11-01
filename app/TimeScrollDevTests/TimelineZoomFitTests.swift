import CoreGraphics
import Foundation
import Testing
@testable import TimeScroll

struct TimelineZoomFitTests {
  private let range = 100.0...300_000.0

  private func fit(_ times: [Int64], width: CGFloat = 600, compressed: Bool) -> Double {
    TimelineZoomFit.msPerPoint(timesAsc: times, targetWidth: width, isCompressed: compressed, compressedGapWidth: 18, range: range)
  }

  @Test func emptyOrInstantSpansZoomAllTheWayIn() {
    #expect(fit([], compressed: false) == range.lowerBound)
    #expect(fit([5_000], compressed: true) == range.lowerBound)
    #expect(fit([5_000, 5_000], compressed: false) == range.lowerBound)
    #expect(fit([0, 600_000], width: 0, compressed: false) == range.lowerBound)
  }

  @Test func linearSpanFillsTheWidth() {
    #expect(fit([0, 300_000, 600_000], compressed: false) == 1_000)
  }

  @Test func linearZoomIsClamped() {
    #expect(fit([0, 1_000], compressed: false) == range.lowerBound)
    #expect(fit([0, 86_400_000 * 30], compressed: false) == range.upperBound)
  }

  @Test func compressedSpanFillsTheWidth() {
    // 61 captures 10 s apart: 60 gaps, each 10 pt wide at 1 s per point.
    let times = (0...60).map { Int64($0) * 10_000 }
    let msPerPoint = fit(times, compressed: true)
    #expect(abs(msPerPoint - 1_000) / 1_000 < 0.001)
  }

  @Test func compressedSpanWithLongIdleGapsStillFits() {
    // Long idle gaps are capped at 18 pt, so only the active stretch decides the zoom.
    var times = (0..<100).map { Int64($0) * 2_000 }
    times += (0..<100).map { 10_000_000 + Int64($0) * 2_000 }
    let msPerPoint = fit(times, compressed: true)
    var width: CGFloat = 0
    for (a, b) in zip(times, times.dropFirst()) { width += min(CGFloat(Double(b - a) / msPerPoint), 18) }
    #expect(abs(width - 600) < 0.5)
  }

  @Test func compressedSpanTooShortToFillZoomsAllTheWayIn() {
    #expect(fit([0, 60_000, 120_000], compressed: true) == range.lowerBound)
  }

  @Test func compressedSpanTooLongToFitZoomsAllTheWayOut() {
    let times = (0..<20_000).map { Int64($0) * 3_000_000 }
    #expect(fit(times, compressed: true) == range.upperBound)
  }
}
