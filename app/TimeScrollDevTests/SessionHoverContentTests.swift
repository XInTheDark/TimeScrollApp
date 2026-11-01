import CoreGraphics
import Foundation
import Testing
@testable import TimeScroll

struct SessionHoverContentTests {
  private func session(apps: [(String?, String?, Int64)], keywords: [String] = [], durationMs: Int64 = 600_000,
                       snapshots: Int = 5) -> ActivitySession {
    ActivitySession(id: 1, startMs: 1_700_000_000_000, endMs: 1_700_000_000_000 + durationMs, snapshotCount: snapshots,
                    apps: apps.map { ActivitySession.AppShare(bundleId: $0.0, name: $0.1, ms: $0.2) }, keywords: keywords)
  }

  @Test func rowsFollowTheAppsWithTheirShareOfTime() {
    let content = SessionHoverContent(session: session(apps: [("a", "A", 300), ("b", nil, 100), (nil, nil, 100)]))
    #expect(content.rows.map(\.name) == ["A", "b", "Unknown"])
    #expect(content.rows.map(\.fraction) == [0.6, 0.2, 0.2])
  }

  @Test func noAppsHaveNoRows() {
    let content = SessionHoverContent(session: session(apps: []))
    #expect(content.rows.isEmpty)
    #expect(content.height == SessionHoverContent.headerHeight + SessionHoverContent.spacing)
  }

  @Test func heightGrowsWithRowsAndKeywords() {
    let plain = SessionHoverContent(session: session(apps: [("a", "A", 1), ("b", "B", 1)]))
    let withKeywords = SessionHoverContent(session: session(apps: [("a", "A", 1), ("b", "B", 1)], keywords: ["x", "y"]))
    #expect(plain.keywordsText == nil)
    #expect(withKeywords.keywordsText == "x, y")
    #expect(withKeywords.height - plain.height == SessionHoverContent.spacing + SessionHoverContent.keywordsHeight)
    let one = SessionHoverContent(session: session(apps: [("a", "A", 1)]))
    #expect(plain.height - one.height == SessionHoverContent.rowHeight)
  }

  @Test func summaryCountsSnapshots() {
    #expect(SessionHoverContent(session: session(apps: [], snapshots: 1)).summaryText.hasSuffix("1 snapshot"))
    #expect(SessionHoverContent(session: session(apps: [], snapshots: 12)).summaryText.hasSuffix("12 snapshots"))
  }

  @Test func durationsUseMinutesOrSeconds() {
    #expect(SessionHoverContent.durationText(ms: 20_000) == "20s")
    #expect(SessionHoverContent.durationText(ms: 33 * 60_000) == "33m")
    #expect(SessionHoverContent.durationText(ms: 95 * 60_000) == "1h 35m")
    #expect(SessionHoverContent.durationText(ms: -5) == "0s")
  }

  @Test func aSessionUnderAMinuteShowsOneTime() {
    let content = SessionHoverContent(session: session(apps: [], durationMs: 20_000))
    #expect(!content.rangeText.contains("–"))
    #expect(SessionHoverContent(session: session(apps: [], durationMs: 600_000)).rangeText.contains("–"))
  }
}
