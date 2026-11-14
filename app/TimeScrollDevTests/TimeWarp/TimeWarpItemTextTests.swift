import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpItemTextTests {
  private func item(_ kind: TimeWarpItemKind, _ value: String, title: String? = nil, frontMs: Int64 = 0, visits: Int = 1,
                    lastSeenMs: Int64 = 0, open: Bool = false) -> TimeWarpPlanItem {
    TimeWarpPlanItem(kind: kind, value: value, title: title, appBundleId: nil, frontMs: frontMs, visits: visits,
                     lastSeenMs: lastSeenMs, wasOpenAtEnd: open)
  }

  private func text(_ item: TimeWarpPlanItem) -> TimeWarpItemText {
    TimeWarpItemText(item: item, appName: { $0 == "com.a" ? "App A" : nil }, homeDirectory: "/Users/me", timeText: { "t\($0)" })
  }

  @Test func pageShowsTitleAndShortLink() {
    let result = text(item(.page, "https://www.example.com/a?b=1", title: "Example", frontMs: 125_000, visits: 3))
    #expect(result.title == "Example")
    #expect(result.subtitle == "example.com/a?…")
    #expect(result.detail == "2m")
    #expect(result.help == "In front for 2m over 3 visits")
  }

  @Test func untitledPageUsesTheLink() {
    #expect(text(item(.page, "https://example.com/x")).title == "example.com/x")
  }

  @Test func filesShowNameAndAbbreviatedFolder() {
    let result = text(item(.document, "/Users/me/Notes/plan.md", title: "Plan"))
    #expect(result.title == "Plan")
    #expect(result.subtitle == "~/Notes")
    let folder = text(item(.folder, "/Users/meeting/src"))
    #expect(folder.title == "src")
    #expect(folder.subtitle == "/Users/meeting")
  }

  @Test func openItemsSayOpen() {
    let result = text(item(.page, "https://a.com/", open: true))
    #expect(result.detail == "Open")
    let both = text(item(.page, "https://a.com/", frontMs: 60_000, open: true))
    #expect(both.help.hasSuffix("still open at the end"))
  }

  @Test func appsUseTheirName() {
    #expect(text(item(.app, "com.a")).title == "App A")
    #expect(text(item(.app, "com.unknown")).title == "com.unknown")
  }

  @Test func abbreviationOnlyMatchesWholeFolders() {
    #expect(TimeWarpItemText.abbreviated("/Users/me", home: "/Users/me") == "~")
    #expect(TimeWarpItemText.abbreviated("/Users/mekong", home: "/Users/me") == "/Users/mekong")
    #expect(TimeWarpItemText.abbreviated("/x", home: "") == "/x")
  }

  // MARK: Moments

  private func momentText(_ item: TimeWarpPlanItem, at moment: Int64) -> TimeWarpItemText {
    TimeWarpItemText(item: item, momentMs: moment, homeDirectory: "/Users/me", timeText: { "t\($0)" })
  }

  @Test func inFrontAtTheMomentSaysSo() {
    var now = item(.page, "https://a/", frontMs: 60_000, lastSeenMs: 2_000_000)
    now.wasFrontAtMoment = true
    #expect(momentText(now, at: 1_000_000).recency == "At this moment")
  }

  @Test func lastInFrontBeforeAnIdleMomentSaysHowLongBefore() {
    var last = item(.page, "https://a/", frontMs: 60_000, lastSeenMs: 1_000_000 - 600_000)
    last.wasFrontAtMoment = true
    #expect(momentText(last, at: 1_000_000).recency == "10m before")
  }

  @Test func earlierItemsSayHowLongBefore() {
    #expect(momentText(item(.page, "https://a/", frontMs: 60_000, lastSeenMs: 1_000_000 - 30_000), at: 1_000_000).recency == "Just before")
    #expect(momentText(item(.page, "https://a/", frontMs: 60_000, lastSeenMs: 1_000_000 - 5_400_000), at: 1_000_000).recency == "1h 30m before")
  }

  @Test func openOnlyItemsAndBlocksHaveNoRecency() {
    #expect(momentText(item(.page, "https://bg/", open: true), at: 1_000_000).recency == nil)
    #expect(text(item(.page, "https://a/", frontMs: 60_000, lastSeenMs: 900_000)).recency == nil)
  }
}
