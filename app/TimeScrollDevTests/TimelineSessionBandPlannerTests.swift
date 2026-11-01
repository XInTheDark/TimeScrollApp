import CoreGraphics
import Foundation
import Testing
@testable import TimeScroll

struct TimelineSessionBandPlannerTests {
  private func session(_ id: Int64, _ start: Int64, _ end: Int64, app: String? = nil, keywords: [String] = []) -> ActivitySession {
    let apps = app.map { [ActivitySession.AppShare(bundleId: "com.\($0)", name: $0, ms: 1)] } ?? []
    return ActivitySession(id: id, startMs: start, endMs: end, snapshotCount: 3, apps: apps, keywords: keywords)
  }

  /// One point per second; every character is 5 points wide.
  private func plan(_ sessions: [ActivitySession], fillsGaps: Bool = false) -> [TimelineSessionBand] {
    TimelineSessionBandPlanner.plan(sessions: sessions, x: { CGFloat($0) / 1000 }, fillsGaps: fillsGaps,
                                    labelWidth: { CGFloat($0.count) * 5 })
  }

  @Test func noSessionsGiveNoBands() {
    #expect(plan([]).isEmpty)
    #expect(TimelineSessionBandPlanner.band(at: 10, in: []) == nil)
  }

  @Test func bandsSpanTheirSessionsWithAGutterBeforeTheNext() {
    let bands = plan([session(1, 0, 100_000), session(2, 100_500, 300_000), session(3, 500_000, 500_000)])
    #expect(bands.map(\.x0) == [0, 100.5, 500])
    #expect(bands[0].x1 == 100.5 - TimelineSessionBandPlanner.gutter)
    #expect(bands[1].x1 == 300)
    #expect(bands[2].width == TimelineSessionBandPlanner.minWidth)
  }

  @Test func compressedBandsRunUpToTheNextOne() {
    let bands = plan([session(1, 0, 100_000), session(2, 400_000, 500_000)], fillsGaps: true)
    #expect(bands[0].x1 == 400 - TimelineSessionBandPlanner.gutter)
    #expect(bands[1].x1 == 500)
  }

  @Test func crowdedBandsNeverOverlap() {
    let sessions = (0..<200).map { session(Int64($0), Int64($0) * 1_500, Int64($0) * 1_500 + 1_000) }
    let bands = plan(sessions, fillsGaps: true)
    for (left, right) in zip(bands, bands.dropFirst()) {
      #expect(left.x1 <= right.x0)
      #expect(left.x1 > left.x0)
    }
  }

  @Test func labelsShortenToFit() {
    let full = session(1, 0, 1_000_000, app: "Xcode", keywords: ["timeline", "sessions"])
    let measure: (String) -> CGFloat = { CGFloat($0.count) * 5 }
    #expect(TimelineSessionBandPlanner.fittedLabel(for: full, width: 1_000, labelWidth: measure) == "Xcode")
    #expect(TimelineSessionBandPlanner.fittedLabel(for: full, width: 40, labelWidth: measure) == "Xcode")
    #expect(TimelineSessionBandPlanner.fittedLabel(for: session(2, 0, 1, app: "Visual Studio Code"), width: 40, labelWidth: measure) == "Visual …")
    #expect(TimelineSessionBandPlanner.fittedLabel(for: full, width: 20, labelWidth: measure) == nil)
  }

  @Test func narrowBandsHaveNoLabel() {
    let bands = plan([session(1, 0, 10_000, app: "Safari"), session(2, 20_000, 400_000, app: "Safari")])
    #expect(bands[0].label == nil)
    #expect(bands[1].label == "Safari")
  }

  @Test func narrowNeighboursDrawAsOneRun() {
    // Three 10 pt sessions in a row, then a wide one.
    let bands = plan([session(1, 0, 10_000), session(2, 12_000, 22_000), session(3, 24_000, 34_000), session(4, 40_000, 400_000)],
                     fillsGaps: true)
    #expect(bands.map(\.runHead) == [0, 0, 0, 3])
    #expect(bands.map(\.runLast) == [2, 2, 2, 3])
    #expect(bands.map(\.isRunTail) == [false, true, true, false])
    #expect(bands[0].drawX1 == bands[2].x1)
    #expect(bands[1].drawX1 == bands[1].x1)
    #expect(bands[0].label == nil)
    #expect(bands[3].drawX1 == bands[3].x1)
  }

  @Test func narrowBandsFarApartStayApart() {
    let bands = plan([session(1, 0, 5_000), session(2, 100_000, 105_000)])
    #expect(bands.map(\.runHead) == [0, 1])
    #expect(bands[0].drawX1 == bands[0].x1)
  }

  @Test func aRunIsHitThroughItsGutters() {
    let bands = plan([session(1, 0, 10_000), session(2, 12_000, 22_000), session(3, 24_000, 34_000)], fillsGaps: true)
    // x = 11 lies in the gutter between the first two bands.
    #expect(bands[0].x1 < 11 && bands[1].x0 > 11)
    #expect(TimelineSessionBandPlanner.band(at: 11, in: bands)?.sessionIndex == 0)
    #expect(TimelineSessionBandPlanner.band(at: 25, in: bands)?.sessionIndex == 2)
    #expect(TimelineSessionBandPlanner.band(at: 40, in: bands) == nil)
  }

  @Test func hitTestingFindsTheBandUnderThePoint() {
    let bands = plan([session(1, 0, 100_000), session(2, 200_000, 300_000)])
    #expect(TimelineSessionBandPlanner.band(at: 50, in: bands)?.sessionIndex == 0)
    #expect(TimelineSessionBandPlanner.band(at: 0, in: bands)?.sessionIndex == 0)
    #expect(TimelineSessionBandPlanner.band(at: 150, in: bands) == nil)
    #expect(TimelineSessionBandPlanner.band(at: 300, in: bands)?.sessionIndex == 1)
    #expect(TimelineSessionBandPlanner.band(at: 301, in: bands) == nil)
    #expect(TimelineSessionBandPlanner.firstIndex(endingAtOrAfter: 150, in: bands) == 1)
    #expect(TimelineSessionBandPlanner.firstIndex(endingAtOrAfter: 1_000, in: bands) == 2)
  }

  @Test func sessionIndexCoversStartThroughLastCapture() {
    let sessions = [session(1, 100, 200), session(2, 300, 300), session(3, 400, 900)]
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 99, in: sessions) == nil)
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 100, in: sessions) == 0)
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 200, in: sessions) == 0)
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 250, in: sessions) == nil)
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 300, in: sessions) == 1)
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 650, in: sessions) == 2)
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 901, in: sessions) == nil)
    #expect(TimelineSessionBandPlanner.sessionIndex(containing: 0, in: []) == nil)
  }
}
