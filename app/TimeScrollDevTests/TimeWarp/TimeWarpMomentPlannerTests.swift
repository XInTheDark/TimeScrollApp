import Foundation
import Testing
@testable import TimeScroll

/// Planning a moment's look-back: what was in front at the moment comes first, then recency.
struct TimeWarpMomentPlannerTests {
  private let moment: Int64 = 10_000_000

  private func record(_ value: String, kind: TimeWarpItemKind = .page, source: TimeWarpSource = .front,
                      _ start: Int64, _ end: Int64) -> TimeWarpSpanRecord {
    TimeWarpSpanRecord(kind: kind, source: source, value: value, title: nil, appBundleId: "com.google.Chrome", startMs: start, endMs: end)
  }

  private func plan(_ records: [TimeWarpSpanRecord], from: Int64 = 0, scope: TimeWarpScope = .visited,
                    momentMs: Int64? = 10_000_000) -> TimeWarpPlan {
    TimeWarpPlanner.plan(records: records, fromMs: from, toMs: moment + 1_000, scope: scope, momentMs: momentMs)
  }

  @Test func whatWasInFrontAtTheMomentComesFirst() {
    let result = plan([record("https://long/", moment - 3_600_000, moment - 600_000),
                       record("https://now/", moment - 20_000, moment + 50_000)])
    let pages = result.items(in: .pages)
    #expect(pages.map(\.value) == ["https://now/", "https://long/"])
    #expect(pages[0].wasFrontAtMoment)
    #expect(!pages[1].wasFrontAtMoment)
    #expect(result.momentMs == moment)
  }

  @Test func recentUseOutranksLongerUseLongAgo() {
    let result = plan([record("https://old/", moment - 7_200_000, moment - 5_400_000), // 30 min, 1.5 h before
                       record("https://recent/", moment - 600_000, moment - 300_000), // 5 min, just before
                       record("https://now/", moment - 1_000, moment + 1_000)])
    #expect(result.items(in: .pages).map(\.value) == ["https://now/", "https://recent/", "https://old/"])
  }

  @Test func idleAtTheMomentMarksWhatWasLastInFront() {
    let result = plan([record("https://earlier/", moment - 900_000, moment - 800_000),
                       record("https://last/", moment - 700_000, moment - 600_000)])
    let last = result.items(in: .pages).first { $0.value == "https://last/" }
    #expect(last?.wasFrontAtMoment == true)
    #expect(result.items(in: .pages).first { $0.value == "https://earlier/" }?.wasFrontAtMoment == false)
  }

  @Test func theAppAndPageInFrontAreBothMarked() {
    let result = plan([record("com.google.Chrome", kind: .app, moment - 60_000, moment + 60_000),
                       record("https://now/", moment - 60_000, moment + 60_000)])
    #expect(result.items(in: .apps).first?.wasFrontAtMoment == true)
    #expect(result.items(in: .pages).first?.wasFrontAtMoment == true)
  }

  @Test func aBlockKeepsRankingByTimeInFront() {
    let result = plan([record("https://long/", moment - 3_600_000, moment - 600_000),
                       record("https://now/", moment - 20_000, moment + 50_000)], momentMs: nil)
    #expect(result.items(in: .pages).map(\.value) == ["https://long/", "https://now/"])
    #expect(result.items(in: .pages).allSatisfy { !$0.wasFrontAtMoment && $0.momentScore == 0 })
  }

  @Test func everythingOpenAtTheMomentIsListed() {
    let result = plan([record("https://bg/", source: .open, moment - 600_000, moment + 600_000),
                       record("https://closed/", source: .open, moment - 600_000, moment - 300_000),
                       record("https://now/", moment - 1_000, moment + 1_000)], scope: .everythingOpen)
    let values = Set(result.items(in: .pages).map(\.value))
    #expect(values == ["https://bg/", "https://now/"])
  }

  @Test func nothingRecordedGivesAnEmptyPlan() {
    #expect(plan([]).isEmpty)
  }

  @Test func manyRecordsStayOrdered() {
    var records: [TimeWarpSpanRecord] = []
    for i in 0..<5_000 {
      let start = Int64(i) * 2_000
      records.append(record("https://p\(i % 50)/", start, start + 1_500))
    }
    let pages = plan(records).items(in: .pages)
    #expect(pages.count == 50)
    #expect(pages.first?.wasFrontAtMoment == true)
    let rest = pages.dropFirst().map(\.momentScore)
    #expect(zip(rest, rest.dropFirst()).allSatisfy { $0 >= $1 })
  }
}
