import Foundation
import Testing
@testable import TimeScroll

struct RepresentativeTextSelectorTests {
  private func session(_ id: Int64, minutes: Int64, app: String = "com.a", textIds: [Int64] = []) -> ActivitySession {
    ActivitySession(id: id, startMs: id * 10_000_000, endMs: id * 10_000_000 + minutes * 60_000, snapshotCount: 1,
                    apps: [.init(bundleId: app, name: app, ms: minutes * 60_000)], keywords: ["kw\(id)"], representativeTextIds: textIds)
  }

  @Test func noSessionsOrNoBudgetAllocateNothing() {
    #expect(RepresentativeTextSelector.allocate(sessions: [], budgetBytes: 10_000).isEmpty)
    #expect(RepresentativeTextSelector.allocate(sessions: [session(1, minutes: 5)], budgetBytes: 0).isEmpty)
    #expect(RepresentativeTextSelector.allocate(sessions: [session(1, minutes: 5)], budgetBytes: -5).isEmpty)
  }

  @Test func sharesFollowTimeAndResultIsInTimeOrder() {
    let allocations = RepresentativeTextSelector.allocate(sessions: [session(2, minutes: 30), session(1, minutes: 10)], budgetBytes: 2_320)
    #expect(allocations.map(\.session.id) == [1, 2])
    #expect(allocations[0].excerptBytes == 500)
    #expect(allocations[1].excerptBytes == 1_500)
  }

  @Test func whenTooManyFitTheLongestSessionsWin() {
    let sessions = (1...1_000).map { session(Int64($0), minutes: Int64($0)) }
    let budget = 10 * (RepresentativeTextSelector.headerBytes + RepresentativeTextSelector.minimumExcerptBytes)
    let allocations = RepresentativeTextSelector.allocate(sessions: sessions, budgetBytes: budget)
    #expect(allocations.count == 10)
    #expect(allocations.map(\.session.id) == Array(991...1_000).map(Int64.init))
  }

  @Test func appFilterKeepsMatchingSessions() {
    let sessions = [session(1, minutes: 5, app: "com.a"), session(2, minutes: 5, app: "com.b")]
    #expect(RepresentativeTextSelector.allocate(sessions: sessions, budgetBytes: 10_000, app: "com.b").map(\.session.id) == [2])
    #expect(RepresentativeTextSelector.allocate(sessions: sessions, budgetBytes: 10_000, app: "com.none").isEmpty)
  }

  @Test func renderStaysInsideTheBudgetWithLongAndMultibyteText() {
    let long = String(repeating: "日本語のテキスト 🧑‍💻 word\n", count: 5_000)
    let sessions = (1...40).map { session(Int64($0), minutes: Int64($0), textIds: [Int64($0), Int64($0) + 100, Int64($0) + 200]) }
    var texts: [Int64: String] = [:]
    for session in sessions { for id in session.representativeTextIds { texts[id] = long } }
    let budget = 20_000
    let allocations = RepresentativeTextSelector.allocate(sessions: sessions, budgetBytes: budget)
    let rendered = RepresentativeTextSelector.render(allocations, texts: texts) { _ in String(repeating: "t", count: 500) }
    #expect(!rendered.isEmpty)
    #expect(rendered.utf8.count <= budget)
  }

  @Test func renderSkipsMissingTextsAndCollapsesWhitespace() {
    let allocations = [RepresentativeTextSelector.Allocation(session: session(1, minutes: 5, textIds: [1, 2]), excerptBytes: 400)]
    let rendered = RepresentativeTextSelector.render(allocations, texts: [2: "alpha\n\n  beta"]) { _ in "09:00" }
    #expect(rendered == "- 09:00, com.a: kw1\nalpha\nbeta\n")
  }

  @Test func truncateRespectsCharacterBoundaries() {
    #expect(RepresentativeTextSelector.truncate("hello", toBytes: 10) == "hello")
    #expect(RepresentativeTextSelector.truncate("hello", toBytes: 2) == "he")
    #expect(RepresentativeTextSelector.truncate("hello", toBytes: 0) == "")
    #expect(RepresentativeTextSelector.truncate("日本語", toBytes: 4) == "日")
    #expect(RepresentativeTextSelector.truncate("🧑‍💻x", toBytes: 3) == "")
  }

  @Test func budgetLeavesRoomForOutputAndPrompt() {
    #expect(SummaryPrompt.contextTokens(modelLimit: nil) == 8_192)
    #expect(SummaryPrompt.contextTokens(modelLimit: 2_048) == 2_048)
    #expect(SummaryPrompt.contextTokens(modelLimit: 262_144) == 8_192)
    #expect(SummaryPrompt.inputBudgetBytes(contextTokens: 8_192) == (8_192 - 1_024 - 300) * 3)
    #expect(SummaryPrompt.inputBudgetBytes(contextTokens: 100) == 0)
  }

  @Test func promptIncludesOnlyWhatExists() {
    let bare = SummaryPrompt.prompt(rangeLabel: "Today", apps: nil, earlierSummaries: [], activity: "")
    #expect(bare == "Period: Today")
    let full = SummaryPrompt.prompt(rangeLabel: "Week", apps: nil, earlierSummaries: [(label: "Mon", text: "did things")], activity: "- record")
    #expect(full.contains("Mon:\ndid things"))
    #expect(full.contains("Activity records:\n- record"))
  }
}
