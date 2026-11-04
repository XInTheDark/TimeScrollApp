import Foundation
import Testing
@testable import TimeScroll

/// Stands in for Ollama, so these tests never start a model.
private final class FakeGenerator: SummaryTextGenerating, @unchecked Sendable {
  var readinessResult = SummaryModelReadiness.ready(contextTokens: nil)
  var output: String? = "A summary."
  var prompts: [String] = []
  var contexts: [Int] = []
  var onGenerate: (() -> Void)?
  var cancelCount = 0

  func readiness(model: String) -> SummaryModelReadiness { readinessResult }

  func generate(model: String, system: String, prompt: String, contextTokens: Int, maxOutputTokens: Int) -> String? {
    prompts.append(prompt)
    contexts.append(contextTokens)
    onGenerate?()
    return output
  }

  func cancel() { cancelCount += 1 }

  func unload(model: String) {}
}

@Suite(.serialized)
final class RangeSummaryProviderTests {
  private let database: SummaryTestDatabase
  private let generator = FakeGenerator()
  private let day: Int64 = 86_400_000
  private let monday = SummaryTestTime.ms(2026, 1, 12)
  private var nowMs = SummaryTestTime.ms(2026, 3, 1)
  private var sessionsByDay: [Int64: [ActivitySession]] = [:]
  private var sessionsAvailable = true
  private var dayLookups = 0
  private lazy var appTime = AppTimeProvider(database: database, calendar: { SummaryTestTime.calendar() },
                                             now: { [unowned self] in self.nowMs }, pauseBetweenBuilds: 0)
  private lazy var provider = RangeSummaryProvider(database: database, generator: generator, appTime: appTime,
                                                   sessionsForDay: { [unowned self] day in
                                                     self.dayLookups += 1
                                                     return self.sessionsAvailable ? self.sessionsByDay[day.startMs, default: []] : nil
                                                   },
                                                   calendar: { SummaryTestTime.calendar() },
                                                   now: { [unowned self] in self.nowMs })

  init() throws {
    database = try SummaryTestDatabase()
  }

  private func addSession(id: Int64, on dayStart: Int64, textId: Int64? = nil, text: String? = nil) {
    let startMs = dayStart + id * 3_600_000
    var ids: [Int64] = []
    if let textId, let text {
      ids = [textId]
      database.storedTexts[textId] = text
    }
    sessionsByDay[dayStart, default: []].append(
      ActivitySession(id: id, startMs: startMs, endMs: startMs + 600_000, snapshotCount: 10,
                      apps: [.init(bundleId: "com.a", name: "Alpha", ms: 600_000)], keywords: ["keyword\(id)"], representativeTextIds: ids))
    database.addCapture(at: startMs, app: "com.a", name: "Alpha")
  }

  private func generate(_ from: Int64, _ to: Int64, model: String = "local") -> RangeSummaryProvider.Result? {
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox()
    provider.generateSummary(fromMs: from, toMs: to, model: model) { result in
      box.value = result
      done.signal()
    }
    guard done.wait(timeout: .now() + 20) == .success else { return nil }
    return box.value
  }

  private final class ResultBox: @unchecked Sendable { var value: RangeSummaryProvider.Result? }

  private func stored(_ from: Int64, _ to: Int64) -> StoredRangeSummary? {
    DB.rangeSummary(startMs: from, endMs: to, db: database.db)
  }

  @Test func readingNeverStartsTheModel() {
    addSession(id: 9, on: monday)
    #expect(provider.summary(fromMs: monday, toMs: monday + day, currentModel: "local") == RangeSummaryProvider.StoredState.none)
    #expect(generator.prompts.isEmpty)
    #expect(dayLookups == 0)
  }

  @Test func embeddedScreensReplaceTheKeywordChoice() {
    addSession(id: 9, on: monday, textId: 1, text: "chosen by keywords")
    let start = monday + 9 * 3_600_000
    database.storedTexts[10] = "chosen by embeddings"
    database.addScreen(at: start + 1_000, textId: 10, vector: [1, 0])
    #expect(generate(monday, monday + day) == .generated(text: "A summary.", stored: true))
    #expect(generator.prompts[0].contains("chosen by embeddings"))
    #expect(!generator.prompts[0].contains("chosen by keywords"))
  }

  @Test func sessionsWithoutEnoughEmbeddingsKeepTheKeywordChoice() {
    addSession(id: 9, on: monday, textId: 1, text: "chosen by keywords")
    let start = monday + 9 * 3_600_000
    database.storedTexts[10] = "chosen by embeddings"
    database.addScreen(at: start + 1_000, textId: 10, vector: [1, 0])
    database.addScreen(at: start + 2_000, textId: 11)
    database.addScreen(at: start + 3_000, textId: 12)
    #expect(generate(monday, monday + day) == .generated(text: "A summary.", stored: true))
    #expect(generator.prompts[0].contains("chosen by keywords"))
    #expect(!generator.prompts[0].contains("chosen by embeddings"))
  }

  @Test func aSettledDayIsGeneratedStoredAndReadBack() {
    addSession(id: 9, on: monday, textId: 1, text: "editing the quarterly plan")
    #expect(generate(monday, monday + day) == .generated(text: "A summary.", stored: true))
    #expect(generator.prompts.count == 1)
    let prompt = generator.prompts[0]
    #expect(prompt.contains("editing the quarterly plan"))
    #expect(prompt.contains("keyword9"))
    #expect(prompt.contains("Alpha"))

    let saved = stored(monday, monday + day)
    #expect(saved?.text == "A summary.")
    #expect(saved?.model == "local")
    #expect(provider.summary(fromMs: monday, toMs: monday + day, currentModel: "local") == .stored(saved!, outdated: false))
  }

  @Test func anotherModelOrPromptMarksAStoredSummaryOutdatedButKeepsIt() {
    addSession(id: 9, on: monday)
    _ = generate(monday, monday + day)
    let saved = stored(monday, monday + day)!
    #expect(provider.summary(fromMs: monday, toMs: monday + day, currentModel: "other") == .stored(saved, outdated: true))
    #expect(provider.summary(fromMs: monday, toMs: monday + day, currentModel: nil) == .stored(saved, outdated: false))
    database.exec("UPDATE ts_range_summary SET prompt_version = 0;")
    if case .stored(_, let outdated) = provider.summary(fromMs: monday, toMs: monday + day, currentModel: "local") {
      #expect(outdated)
    } else {
      Issue.record("expected a stored summary")
    }
  }

  @Test func arbitraryAndUnfinishedRangesAreNotStored() {
    addSession(id: 9, on: monday)
    #expect(generate(monday + 8 * 3_600_000, monday + 11 * 3_600_000) == .generated(text: "A summary.", stored: false))
    nowMs = monday + 12 * 3_600_000
    #expect(generate(monday, monday + day) == .generated(text: "A summary.", stored: false))
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary;") == 0)
  }

  @Test func noActivityDoesNotCallTheModel() {
    #expect(generate(monday, monday + day) == .noActivity)
    #expect(generate(monday, monday) == .noActivity)
    #expect(generator.prompts.isEmpty)
  }

  @Test func eachUnavailableStateIsReportedWithoutGenerating() {
    addSession(id: 9, on: monday)
    let cases: [(SummaryModelReadiness, RangeSummaryProvider.Result)] = [
      (.ollamaUnavailable, .ollamaUnavailable), (.modelNotInstalled, .modelNotInstalled),
      (.modelUnsuitable, .modelUnsuitable), (.cloudModelRefused, .cloudModelRefused),
    ]
    for (readiness, expected) in cases {
      generator.readinessResult = readiness
      #expect(generate(monday, monday + day) == expected)
    }
    #expect(generator.prompts.isEmpty)
    #expect(dayLookups == 0)
  }

  @Test func aFailedGenerationStoresNothing() {
    addSession(id: 9, on: monday)
    generator.output = nil
    #expect(generate(monday, monday + day) == .failed)
    generator.output = ""
    #expect(generate(monday, monday + day) == .failed)
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary;") == 0)
  }

  @Test func aDeleteDuringGenerationDiscardsTheResult() {
    addSession(id: 9, on: monday)
    generator.onGenerate = { [database, monday] in
      database.exec(DB.summaryInvalidationSQL(captureAt: "\(monday + 1_000)"))
    }
    #expect(generate(monday, monday + day) == .discarded)
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary;") == 0)
    // The same applies to ranges that wouldn't be stored.
    #expect(generate(monday + 8 * 3_600_000, monday + 11 * 3_600_000) == .discarded)
  }

  @Test func aDeleteRemovesOverlappingSummariesOnly() {
    addSession(id: 9, on: monday)
    addSession(id: 9, on: monday + day)
    _ = generate(monday, monday + day)
    _ = generate(monday + day, monday + 2 * day)
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary;") == 2)
    database.exec(DB.summaryInvalidationSQL(captureAt: "\(monday + 1_000)"))
    #expect(stored(monday, monday + day) == nil)
    #expect(stored(monday + day, monday + 2 * day) != nil)
  }

  @Test func clearingAllTextRemovesAllSummaries() {
    addSession(id: 9, on: monday)
    _ = generate(monday, monday + day)
    database.exec(DB.allRangeSummariesDeletionSQL)
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary;") == 0)
  }

  @Test func retentionRemovesSummariesThatStartBeforeTheCutoff() {
    addSession(id: 9, on: monday)
    addSession(id: 9, on: monday + day)
    _ = generate(monday, monday + day)
    _ = generate(monday + day, monday + 2 * day)
    database.exec(DB.summaryRetentionSQL(cutoffMs: monday + 3_600_000))
    #expect(stored(monday, monday + day) == nil)
    #expect(stored(monday + day, monday + 2 * day) != nil)
  }

  @Test func aWeekReusesStoredDaysInOneCall() {
    for offset in 0..<7 { addSession(id: 9, on: monday + Int64(offset) * day) }
    generator.output = "Monday's summary."
    _ = generate(monday, monday + day)
    generator.output = "Week summary."
    let before = generator.prompts.count
    #expect(generate(monday, monday + 7 * day) == .generated(text: "Week summary.", stored: true))
    #expect(generator.prompts.count == before + 1)
    let prompt = generator.prompts.last!
    #expect(prompt.contains("Monday's summary."))
    #expect(stored(monday, monday + 7 * day) != nil)
    #expect(prompt.contains("Measured:"))
    // Once for Monday's summary, and once per day to build its ledger. Ledgers are stored after that.
    #expect(dayLookups == 1 + 7)
    _ = generate(monday, monday + 7 * day)
    #expect(dayLookups == 1 + 7)
  }

  @Test func aLongRangeWithNothingStoredIsStillOneCallAndFitsTheContext() {
    let text = String(repeating: "words on the screen ", count: 2_000)
    for offset in 0..<60 {
      let dayStart = monday + Int64(offset) * day
      for id in 9...14 { addSession(id: Int64(id), on: dayStart, textId: Int64(offset * 100 + id), text: text) }
    }
    nowMs = monday + 70 * day
    #expect(generate(monday, monday + 60 * day) == .generated(text: "A summary.", stored: false))
    #expect(generator.prompts.count == 1)
    let budget = SummaryPrompt.inputBudgetBytes(contextTokens: generator.contexts[0])
    #expect(generator.prompts[0].utf8.count < budget + SummaryPrompt.overheadTokens * SummaryPrompt.bytesPerToken)
  }

  @Test func aMonthUsesLedgersAndDoesntNeedTheModelForThem() {
    for offset in 0..<28 { addSession(id: 9, on: monday + Int64(offset) * day) }
    nowMs = monday + 40 * day
    #expect(generate(monday, monday + 28 * day) == .generated(text: "A summary.", stored: false))
    let prompt = generator.prompts[0]
    #expect(prompt.contains("Measured:"))
    #expect(prompt.contains("keyword9"))
    #expect(DB.activityLedgers(fromMs: monday, toMs: monday + 28 * day, db: database.db).count == 28)
  }

  @Test func aDeleteRemovesTheLedgerAndItRebuilds() {
    for offset in 0..<3 { addSession(id: 9, on: monday + Int64(offset) * day) }
    nowMs = monday + 10 * day
    _ = generate(monday, monday + 3 * day)
    database.exec(DB.summaryInvalidationSQL(capturesFromMs: monday + day + 3_600_000, throughMs: monday + day + 3_600_000))
    let left = DB.activityLedgers(fromMs: monday, toMs: monday + 3 * day, db: database.db)
    #expect(left[monday + day] == nil)
    #expect(left[monday + 2 * day] != nil)
    let lookups = dayLookups
    _ = generate(monday, monday + 3 * day)
    #expect(dayLookups > lookups)
  }

  @Test func retentionAndClearingRemoveLedgers() {
    for offset in 0..<3 { addSession(id: 9, on: monday + Int64(offset) * day) }
    nowMs = monday + 10 * day
    _ = generate(monday, monday + 3 * day)
    database.exec(DB.summaryRetentionSQL(cutoffMs: monday + day))
    #expect(DB.activityLedgers(fromMs: monday, toMs: monday + 3 * day, db: database.db)[monday] == nil)
    database.exec(DB.allRangeSummariesDeletionSQL)
    #expect(DB.activityLedgers(fromMs: monday, toMs: monday + 3 * day, db: database.db).isEmpty)
  }

  @Test func anUnfinishedDayGetsNoStoredLedger() {
    for offset in 0..<3 { addSession(id: 9, on: monday + Int64(offset) * day) }
    nowMs = monday + 3 * day - 1
    _ = generate(monday, monday + 3 * day)
    let ledgers = DB.activityLedgers(fromMs: monday, toMs: monday + 3 * day, db: database.db)
    #expect(ledgers[monday] != nil)
    #expect(ledgers[monday + 2 * day] == nil)
  }

  @Test func aLongRangeWithNoActivityDoesNotCallTheModel() {
    nowMs = monday + 40 * day
    #expect(generate(monday, monday + 30 * day) == .noActivity)
    #expect(generator.prompts.isEmpty)
  }

  @Test func aUserRequestStopsABackgroundOne() {
    addSession(id: 9, on: monday)
    addSession(id: 9, on: monday + day)
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    generator.onGenerate = {
      started.signal()
      _ = release.wait(timeout: .now() + 10)
    }
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox()
    provider.generateSummary(fromMs: monday, toMs: monday + day, model: "local", background: true) { result in
      box.value = result
      done.signal()
    }
    #expect(started.wait(timeout: .now() + 10) == .success)
    let userDone = DispatchSemaphore(value: 0)
    provider.generateSummary(fromMs: monday + day, toMs: monday + 2 * day, model: "local") { _ in userDone.signal() }
    #expect(generator.cancelCount == 1)
    generator.onGenerate = nil
    release.signal()
    #expect(done.wait(timeout: .now() + 10) == .success)
    #expect(userDone.wait(timeout: .now() + 10) == .success)
    #expect(box.value == .cancelled)
    #expect(stored(monday, monday + day) == nil)
  }

  @Test func aSameRangeUserRequestPromotesBackgroundWork() {
    addSession(id: 9, on: monday)
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var calls = 0
    generator.onGenerate = {
      calls += 1
      if calls == 1 {
        started.signal()
        _ = release.wait(timeout: .now() + 10)
      }
    }
    let backgroundDone = DispatchSemaphore(value: 0)
    let userDone = DispatchSemaphore(value: 0)
    var backgroundResult: RangeSummaryProvider.Result?
    var userResult: RangeSummaryProvider.Result?
    provider.generateSummary(fromMs: monday, toMs: monday + day, model: "local", background: true) { result in
      backgroundResult = result
      backgroundDone.signal()
    }
    #expect(started.wait(timeout: .now() + 10) == .success)
    provider.generateSummary(fromMs: monday, toMs: monday + day, model: "local") { result in
      userResult = result
      userDone.signal()
    }
    #expect(generator.cancelCount == 1)
    generator.onGenerate = nil
    release.signal()
    #expect(backgroundDone.wait(timeout: .now() + 10) == .success)
    #expect(userDone.wait(timeout: .now() + 10) == .success)
    #expect(backgroundResult == .generated(text: "A summary.", stored: true))
    #expect(userResult == .generated(text: "A summary.", stored: true))
    #expect(generator.prompts.count == 2)
  }

  @Test func aSmallModelGetsASmallerContext() {
    addSession(id: 9, on: monday)
    generator.readinessResult = .ready(contextTokens: 2_048)
    _ = generate(monday, monday + day)
    #expect(generator.contexts == [2_048])
  }

  @Test func regeneratingReplacesTheStoredSummary() {
    addSession(id: 9, on: monday)
    _ = generate(monday, monday + day)
    generator.output = "Better."
    #expect(generate(monday, monday + day, model: "other") == .generated(text: "Better.", stored: true))
    #expect(stored(monday, monday + day)?.text == "Better.")
    #expect(stored(monday, monday + day)?.model == "other")
    #expect(!generator.prompts.last!.contains("A summary."))
  }

  @Test func aLockedVaultStopsGeneration() {
    addSession(id: 9, on: monday)
    database.isLocked = true
    #expect(generate(monday, monday + day) == .vaultLocked)
    #expect(provider.summary(fromMs: monday, toMs: monday + day, currentModel: nil) == nil)
    #expect(generator.prompts.isEmpty)
  }

  @Test func sessionsBecomingUnavailableStopGeneration() {
    addSession(id: 9, on: monday)
    sessionsAvailable = false
    #expect(generate(monday, monday + day) == .vaultLocked)
    #expect(generator.prompts.isEmpty)
  }

  @Test func lockingDuringGenerationCancelsAndDiscards() {
    addSession(id: 9, on: monday)
    generator.onGenerate = { [unowned self] in provider.cancelRunning() }
    #expect(generate(monday, monday + day) == .cancelled)
    #expect(generator.cancelCount == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary;") == 0)
    // A later request works normally.
    generator.onGenerate = nil
    #expect(generate(monday, monday + day) == .generated(text: "A summary.", stored: true))
  }

  @Test func aSecondRequestForTheSameRangeJoinsTheFirst() {
    addSession(id: 9, on: monday)
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    generator.onGenerate = {
      started.signal()
      release.wait()
    }
    let finished = DispatchGroup()
    let lock = NSLock()
    var results: [RangeSummaryProvider.Result] = []
    func request() {
      finished.enter()
      provider.generateSummary(fromMs: monday, toMs: monday + day, model: "local") { result in
        lock.lock()
        results.append(result)
        lock.unlock()
        finished.leave()
      }
    }
    request()
    #expect(started.wait(timeout: .now() + 10) == .success)
    request()
    release.signal()
    #expect(finished.wait(timeout: .now() + 10) == .success)
    #expect(results.count == 2)
    #expect(generator.prompts.count == 1)
  }
}
