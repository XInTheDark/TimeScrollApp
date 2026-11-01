import Foundation
import Testing
@testable import TimeScroll

struct SearchSessionGrouperTests {
  static func hit(_ id: Int64, at time: Int64, kind: CaptureKind = .screen) -> SearchResult {
    SearchResult(id: id, startedAtMs: time, endedAtMs: nil, path: "/tmp/\(id)", appBundleId: "com.app", appName: "App",
                 thumbPath: nil, captureKind: kind, audioSourceKind: nil, audioAssetId: nil, audioDurationMs: nil, content: "")
  }

  static func session(_ id: Int64, _ start: Int64, _ end: Int64) -> ActivitySession {
    ActivitySession(id: id, startMs: start, endMs: end, snapshotCount: 2, apps: [], keywords: [])
  }

  private let sessions = [session(1, 1_000_000, 2_000_000), session(2, 5_000_000, 6_000_000)]

  @Test func emptyHitsGiveNoGroups() {
    #expect(SearchSessionGrouper.group([], sessions: sessions).isEmpty)
  }

  @Test func groupsKeepTheOrderOfTheirBestHit() {
    let hits = [Self.hit(10, at: 5_500_000), Self.hit(11, at: 1_500_000), Self.hit(12, at: 5_200_000),
                Self.hit(13, at: 3_500_000), Self.hit(14, at: 1_100_000)]
    let groups = SearchSessionGrouper.group(hits, sessions: sessions)
    #expect(groups.map(\.session?.id) == [2, 1, nil])
    #expect(groups.map { $0.hits.map(\.id) } == [[10, 12], [11, 14], [13]])
    #expect(groups.map(\.best.id) == [10, 11, 13])
    #expect(groups.map(\.id) == ["s2", "s1", "h13"])
  }

  @Test func hitsOutsideEverySessionStayApartWithUniqueIds() {
    let hits = [Self.hit(1, at: 10), Self.hit(2, at: 20), Self.hit(3, at: 30)]
    let groups = SearchSessionGrouper.group(hits, sessions: [])
    #expect(groups.count == 3)
    #expect(Set(groups.map(\.id)).count == 3)
    #expect(groups.allSatisfy { $0.session == nil && $0.hits.count == 1 })
  }

  @Test func hitsJustPastASessionBelongToIt() {
    let tolerance = SearchSessionGrouper.matchToleranceMs
    #expect(SearchSessionGrouper.session(containing: 2_000_000 + tolerance, in: sessions)?.id == 1)
    #expect(SearchSessionGrouper.session(containing: 1_000_000 - tolerance, in: sessions)?.id == 1)
    #expect(SearchSessionGrouper.session(containing: 2_000_001 + tolerance, in: sessions) == nil)
    #expect(SearchSessionGrouper.session(containing: 0, in: sessions) == nil)
    #expect(SearchSessionGrouper.session(containing: 9_000_000, in: sessions) == nil)
    #expect(SearchSessionGrouper.session(containing: 1_500_000, in: []) == nil)
  }

  @Test func overlappingTolerancesPickTheNearestSession() {
    let close = [Self.session(1, 0, 100_000), Self.session(2, 150_000, 300_000)]
    #expect(SearchSessionGrouper.session(containing: 110_000, in: close)?.id == 1)
    #expect(SearchSessionGrouper.session(containing: 140_000, in: close)?.id == 2)
    #expect(SearchSessionGrouper.session(containing: 150_000, in: close)?.id == 2)
    #expect(SearchSessionGrouper.session(containing: 100_000, in: close)?.id == 1)
  }

  @Test func audioHitsGroupWithTheSessionTheyFallIn() {
    let groups = SearchSessionGrouper.group([Self.hit(1, at: 1_200_000, kind: .audio), Self.hit(2, at: 1_300_000)], sessions: sessions)
    #expect(groups.count == 1)
    #expect(groups[0].hits.map(\.id) == [1, 2])
  }

  @Test func manySessionsStillFindTheRightOne() {
    let many = (0..<10_000).map { Self.session(Int64($0), Int64($0) * 1_000_000, Int64($0) * 1_000_000 + 500_000) }
    #expect(SearchSessionGrouper.session(containing: 7_654_000_250, in: many)?.id == 7_654)
    #expect(SearchSessionGrouper.session(containing: 7_654_800_000, in: many) == nil)
  }
}
