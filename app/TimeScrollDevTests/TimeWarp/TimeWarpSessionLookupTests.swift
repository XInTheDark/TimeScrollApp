import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpSessionLookupTests {
  private func session(_ start: Int64, _ end: Int64) -> ActivitySession {
    ActivitySession(id: start, startMs: start, endMs: end, snapshotCount: 2, apps: [], keywords: [])
  }

  @Test func findsTheSessionContainingTheMoment() {
    let sessions = [session(0, 1_000_000), session(2_000_000, 3_000_000)]
    #expect(TimeWarpSessionLookup.start(containing: 2_500_000, in: sessions) == 2_000_000)
    #expect(TimeWarpSessionLookup.start(containing: 2_000_000, in: sessions) == 2_000_000)
  }

  @Test func aMomentJustAfterTheLastSnapshotStillCounts() {
    let sessions = [session(0, 1_000_000)]
    #expect(TimeWarpSessionLookup.start(containing: 1_000_000 + TimeWarpSessionLookup.toleranceMs, in: sessions) == 0)
    #expect(TimeWarpSessionLookup.start(containing: 1_000_001 + TimeWarpSessionLookup.toleranceMs, in: sessions) == nil)
  }

  @Test func noSessionsOrAGapGivesNone() {
    #expect(TimeWarpSessionLookup.start(containing: 5, in: []) == nil)
    #expect(TimeWarpSessionLookup.start(containing: 1_500_000 + TimeWarpSessionLookup.toleranceMs,
                                        in: [session(0, 1_000_000), session(2_000_000, 3_000_000)]) == nil)
  }

  @Test func overlappingSessionsPickTheLatest() {
    let sessions = [session(0, 2_000_000), session(1_900_000, 3_000_000)]
    #expect(TimeWarpSessionLookup.start(containing: 1_950_000, in: sessions) == 1_900_000)
  }
}
