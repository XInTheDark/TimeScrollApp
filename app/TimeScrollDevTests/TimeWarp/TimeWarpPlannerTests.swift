import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpPlannerTests {
  private func record(_ value: String, kind: TimeWarpItemKind = .page, source: TimeWarpSource = .front, title: String? = nil,
                      app: String? = "com.google.Chrome", _ start: Int64, _ end: Int64) -> TimeWarpSpanRecord {
    TimeWarpSpanRecord(kind: kind, source: source, value: value, title: title, appBundleId: app, startMs: start, endMs: end)
  }

  private func plan(_ records: [TimeWarpSpanRecord], _ from: Int64 = 0, _ to: Int64 = 100_000,
                    scope: TimeWarpScope = .visited) -> TimeWarpPlan {
    TimeWarpPlanner.plan(records: records, fromMs: from, toMs: to, scope: scope)
  }

  @Test func emptyRecordsGiveAnEmptyPlan() {
    #expect(plan([]).isEmpty)
    #expect(plan([], 10, 10).isEmpty)
  }

  @Test func timeInFrontIsClippedToTheBlock() {
    let result = plan([record("https://a/", -50_000, 30_000), record("https://a/", 90_000, 200_000)])
    let item = result.items(in: .pages).first
    #expect(item?.frontMs == 40_000)
    #expect(item?.visits == 2)
    #expect(item?.lastSeenMs == 200_000)
  }

  @Test func shortGapsContinueAVisit() {
    let result = plan([record("https://a/", 0, 10_000), record("https://a/", 12_000, 20_000), record("https://a/", 40_000, 41_000)])
    #expect(result.items(in: .pages).first?.visits == 2)
  }

  @Test func itemsAreRankedByTimeInFront() {
    let result = plan([record("https://a/", 0, 1_000), record("https://b/", 1_000, 50_000), record("https://c/", 50_000, 60_000)])
    #expect(result.items(in: .pages).map(\.value) == ["https://b/", "https://c/", "https://a/"])
  }

  @Test func latestTitleWinsAndMostUsedAppIsKept() {
    let result = plan([record("https://a/", title: "Old", app: "com.apple.Safari", 0, 1_000),
                       record("https://a/", title: "New", 2_000, 30_000)])
    let item = result.items(in: .pages).first
    #expect(item?.title == "New")
    #expect(item?.appBundleId == "com.google.Chrome")
  }

  @Test func spansOutsideTheBlockAreIgnored() {
    #expect(plan([record("https://a/", 200_000, 300_000), record("https://b/", -5_000, 0)]).isEmpty)
  }

  @Test func kindsGoToTheirGroups() {
    let result = plan([record("/a.pdf", kind: .document, 0, 10), record("/src", kind: .folder, 0, 10), record("com.a", kind: .app, app: "com.a", 0, 10)])
    #expect(result.items(in: .documents).count == 1)
    #expect(result.items(in: .folders).count == 1)
    #expect(result.items(in: .apps).first?.appBundleId == "com.a")
  }

  @Test func warpPointsBecomeNotesInOrder() {
    let result = plan([record("second", kind: .warpPoint, source: .event, 20_000, 20_000),
                       record("first", kind: .warpPoint, source: .event, 0, 0)])
    #expect(result.notes.map(\.note) == ["first", "second"])
    #expect(result.items(in: .pages).isEmpty)
  }

  @Test func openItemsOnlyInEverythingOpen() {
    let records = [record("https://front/", 0, 50_000), record("https://bg/", source: .open, 0, 100_000)]
    #expect(plan(records).items(in: .pages).count == 1)
    #expect(plan(records).hasOpenItems)
    let open = plan(records, scope: .everythingOpen).items(in: .pages)
    #expect(open.count == 2)
    #expect(open.first { $0.value == "https://bg/" }?.wasOpenAtEnd == true)
  }

  @Test func onlyItemsStillOpenAtTheEndCount() {
    let records = [record("https://closed/", source: .open, 0, 10_000), record("https://kept/", source: .open, 0, 100_000)]
    #expect(plan(records, scope: .everythingOpen).items(in: .pages).map(\.value) == ["https://kept/"])
  }

  @Test func recordingThatStoppedEarlyAnchorsAtItsLastMoment() {
    // Recording stopped at 60 s; what was open then is what was open at the end.
    let records = [record("https://a/", source: .open, 0, 60_000), record("https://b/", source: .open, 0, 30_000)]
    #expect(plan(records, scope: .everythingOpen).items(in: .pages).map(\.value) == ["https://a/"])
  }

  @Test func frontItemThatWasOpenAtTheEndIsMarked() {
    let records = [record("https://a/", 0, 10_000), record("https://a/", source: .open, 0, 100_000)]
    let item = plan(records, scope: .everythingOpen).items(in: .pages).first
    #expect(item?.frontMs == 10_000)
    #expect(item?.wasOpenAtEnd == true)
  }

  @Test func blockAcrossMidnightAndDSTUsesAbsoluteTime() {
    // 2025-03-30 00:30 to 03:30 in Europe/London spans the clocks going forward: 2 real hours.
    let calendar = SummaryTestTime.calendar("Europe/London")
    let from = Int64(calendar.date(from: DateComponents(year: 2025, month: 3, day: 30, hour: 0, minute: 30))!.timeIntervalSince1970 * 1000)
    let to = Int64(calendar.date(from: DateComponents(year: 2025, month: 3, day: 30, hour: 3, minute: 30))!.timeIntervalSince1970 * 1000)
    #expect(to - from == Int64(7_200_000))
    let result = plan([record("https://a/", from - 3_600_000, to + 3_600_000)], from, to)
    #expect(result.items(in: .pages).first?.frontMs == Int64(7_200_000))
  }

  @Test func manyRecordsStayCorrect() {
    var records: [TimeWarpSpanRecord] = []
    for index in 0..<20_000 {
      let start = Int64(index) * 1_000
      records.append(record("https://site/\(index % 100)", start, start + 1_000))
    }
    let result = plan(records, 0, 20_000_000)
    #expect(result.items(in: .pages).count == 100)
    #expect(result.items(in: .pages).allSatisfy { $0.frontMs == 200_000 && $0.visits == 200 })
  }
}
