import Foundation
import Testing
@testable import TimeScroll

struct ActivityLedgerTests {
  private func session(_ id: Int64, minutes: Int64, keywords: [String] = ["kw"], textIds: [Int64] = [], app: String = "Alpha") -> ActivitySession {
    let ms = minutes * 60_000
    return ActivitySession(id: id, startMs: id * 3_600_000, endMs: id * 3_600_000 + ms, snapshotCount: 5,
                           apps: [.init(bundleId: "com.a", name: app, ms: ms)], keywords: keywords, representativeTextIds: textIds)
  }

  @Test func noSessionsMakeAnEmptyLedger() {
    let ledger = ActivityLedgerBuilder.build(startMs: 0, endMs: 10, sessions: [], texts: [:])
    #expect(ledger.isEmpty)
    #expect(ActivityLedgerRenderer.render(ledger, toBytes: 1_000) == "")
  }

  @Test func oneSessionKeepsItsFacts() {
    let ledger = ActivityLedgerBuilder.build(startMs: 0, endMs: 10, sessions: [session(1, minutes: 10, keywords: ["vault"], textIds: [1])],
                                             texts: [1: "Open Report.pdf about the vault migration\nOK"])
    #expect(ledger.apps.map(\.name) == ["Alpha"])
    #expect(ledger.activeMs == 600_000)
    #expect(ledger.terms.map(\.name).contains("vault"))
    #expect(ledger.terms.map(\.name).contains("Report.pdf"))
    #expect(ledger.lines.first?.text.contains("vault") == true)
  }

  @Test func aBusyDayStaysBoundedAndLoadsTextForTopSessionsOnly() {
    let sessions = (1...500).map { session(Int64($0), minutes: Int64($0), keywords: ["word\($0)"], textIds: [Int64($0)]) }
    #expect(ActivityLedgerBuilder.textIds(for: sessions).count == ActivityLedgerBuilder.sessionsWithText)
    let text = String(repeating: "some line of screen text that goes on\n", count: 5_000)
    let texts = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, text) })
    let ledger = ActivityLedgerBuilder.build(startMs: 0, endMs: 10, sessions: sessions, texts: texts)
    #expect(ledger.terms.count == ActivityLedger.maxTerms)
    #expect(ledger.lines.count <= ActivityLedger.maxLines)
    #expect(ledger.lines.allSatisfy { $0.text.utf8.count <= ActivityLedger.maxLineBytes })
    #expect(ledger.activeMs == sessions.reduce(0) { $0 + $1.apps[0].ms })
  }

  @Test func mergingAddsTimeIgnoresCaseAndSharesLinesEvenly() {
    let line = { (t: String) in ActivityLedger.Line(timeMs: 0, text: t) }
    let first = ActivityLedger(startMs: 0, endMs: 1, activeMs: 10, apps: [.init(name: "Xcode", ms: 10)], terms: [.init(name: "Vault", ms: 10)],
                               lines: (0..<60).map { line("a\($0)") })
    let second = ActivityLedger(startMs: 1, endMs: 2, activeMs: 5, apps: [.init(name: "Xcode", ms: 5)], terms: [.init(name: "vault", ms: 5)],
                                lines: [line("b0")])
    let merged = ActivityLedgerMerger.merge([first, second], startMs: 0, endMs: 2)
    #expect(merged.activeMs == 15)
    #expect(merged.apps == [.init(name: "Xcode", ms: 15)])
    #expect(merged.terms == [.init(name: "Vault", ms: 15)])
    #expect(merged.lines.prefix(2).map(\.text) == ["a0", "b0"])
    #expect(merged.lines.count == ActivityLedgerMerger.maxMergedLines)
  }

  @Test func mergingNothingIsEmpty() {
    #expect(ActivityLedgerMerger.merge([], startMs: 0, endMs: 1).isEmpty)
  }

  @Test func renderingNeverExceedsTheLimit() {
    let amounts = (0..<50).map { ActivityLedger.Amount(name: "日本語の名前\($0)", ms: 1) }
    let lines = (0..<50).map { _ in ActivityLedger.Line(timeMs: 0, text: String(repeating: "語", count: 50)) }
    let ledger = ActivityLedger(startMs: 0, endMs: 1, activeMs: 1, apps: amounts, terms: amounts, lines: lines)
    for limit in [0, 1, 10, 100, 500, 2_000, 20_000] {
      #expect(ActivityLedgerRenderer.render(ledger, toBytes: limit).utf8.count <= limit)
    }
  }

  @Test func theLedgerSurvivesStorageEncoding() throws {
    let ledger = ActivityLedger(startMs: 1, endMs: 2, activeMs: 3, apps: [.init(name: "A", ms: 1)], terms: [], lines: [.init(timeMs: 1, text: "語 \"x\"")])
    #expect(try JSONDecoder().decode(ActivityLedger.self, from: JSONEncoder().encode(ledger)) == ledger)
  }
}
