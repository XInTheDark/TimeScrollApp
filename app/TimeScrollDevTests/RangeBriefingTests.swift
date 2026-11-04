import Foundation
import Testing
@testable import TimeScroll

struct RangeBriefingTests {
  private func ledger(_ term: String) -> ActivityLedger {
    ActivityLedger(startMs: 0, endMs: 1, activeMs: 1, apps: [.init(name: "App", ms: 1)], terms: [.init(name: term, ms: 1)],
                   lines: (0..<40).map { .init(timeMs: 0, text: "\(term) line \($0) " + String(repeating: "x", count: 100)) })
  }

  @Test func theLastPeriodAlwaysGetsItsShare() {
    let sections = (0..<12).map { RangeBriefing.Section(label: "Month \($0)", ledger: ledger("term\($0)"), summaries: []) }
    let text = RangeBriefing.render(sections, budgetBytes: 6_000)
    #expect(text.contains("[Month 0]"))
    #expect(text.contains("[Month 11]"))
    #expect(text.contains("term11"))
    #expect(text.utf8.count <= 6_000)
  }

  @Test func emptyPeriodsGiveTheirShareToOthers() {
    let empty = ActivityLedger(startMs: 0, endMs: 1, activeMs: 0, apps: [], terms: [], lines: [])
    let sections = [RangeBriefing.Section(label: "Empty", ledger: empty, summaries: []), RangeBriefing.Section(label: "Busy", ledger: ledger("t"), summaries: [])]
    let text = RangeBriefing.render(sections, budgetBytes: 3_000)
    #expect(!text.contains("Empty"))
    #expect(text.utf8.count > 2_000)
  }

  @Test func aSummaryAndItsLedgerBothAppear() {
    let section = RangeBriefing.Section(label: "Week", ledger: ledger("vault"), summaries: [(label: "Mon", text: "Overview.\n\nTopic\nDid things.")])
    let text = RangeBriefing.render([section], budgetBytes: 2_000)
    #expect(text.contains("Earlier summary, Mon:\nOverview."))
    #expect(text.contains("Measured:\n"))
  }

  @Test func noSectionsOrNoBudgetGiveNothing() {
    #expect(RangeBriefing.render([], budgetBytes: 1_000) == "")
    #expect(RangeBriefing.render([RangeBriefing.Section(label: "A", ledger: ledger("t"), summaries: [])], budgetBytes: 0) == "")
  }

  @Test func staysInsideTheBudgetWithManySummaries() {
    let long = (0..<8).map { "Topic \($0)\n" + String(repeating: "語", count: 300) }.joined(separator: "\n\n")
    let sections = (0..<60).map { i in
      RangeBriefing.Section(label: "S\(i)", ledger: ledger("t"), summaries: (0..<5).map { (label: "P\($0)", text: long) })
    }
    #expect(RangeBriefing.render(sections, budgetBytes: 20_000).utf8.count <= 20_000)
  }

  @Test func trimmingKeepsWholeBlocksFromTheStart() {
    let text = "Overview here.\n\nFirst\nBody one.\n\nSecond\nBody two."
    #expect(SummaryOutput.trim(text, toBytes: 1_000) == text)
    #expect(SummaryOutput.trim(text, toBytes: 32) == "Overview here.\n\nFirst\nBody one.")
    #expect(SummaryOutput.trim(text, toBytes: 5) == "Overv")
    #expect(SummaryOutput.trim(text, toBytes: 0) == "")
  }
}
