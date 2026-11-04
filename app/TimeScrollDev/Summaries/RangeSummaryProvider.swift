import Foundation

/// Reads stored summaries, and generates a new one only when asked. Opening a view never starts the
/// model, and nothing generates in the background.
final class RangeSummaryProvider: @unchecked Sendable {
  static let shared = RangeSummaryProvider(
    database: SharedSummaryDatabase(),
    generator: OllamaTextGenerator(),
    appTime: .shared,
    sessionsForDay: { day in
      ActivitySessionProvider.shared.sessions(coveringTimes: [day.startMs], sensitivity: SessionSensitivity.stored())
    })

  enum StoredState: Equatable {
    case none
    /// `outdated` when made with another model or prompt. It stays usable.
    case stored(StoredRangeSummary, outdated: Bool)
  }

  enum Result: Equatable {
    case generated(text: String, stored: Bool)
    case noActivity
    case ollamaUnavailable
    case modelNotInstalled
    case modelUnsuitable
    case cloudModelRefused
    case failed
    /// Captures in the range changed while the model ran, so the text may describe deleted data.
    case discarded
    case cancelled
    case vaultLocked
  }

  private struct Key: Hashable {
    let fromMs: Int64
    let toMs: Int64
    let model: String
  }

  private let database: SummaryDatabase
  private let generator: SummaryTextGenerating
  private let appTime: AppTimeProvider
  private let sessionsForDay: (SessionDayPlanner.Day) -> [ActivitySession]?
  private let ledgers: ActivityLedgerStore
  private let calendar: () -> Calendar
  private let now: () -> Int64
  private let queue = DispatchQueue(label: "TimeScroll.RangeSummary", qos: .utility)
  private let lock = NSLock()
  private var waiting: [Key: [(Result) -> Void]] = [:]
  private var foregroundPromotions = Set<Key>()
  private var lockEpoch = 0
  private var backgroundKey: Key?
  private var backgroundPreempted = false

  init(database: SummaryDatabase,
       generator: SummaryTextGenerating,
       appTime: AppTimeProvider,
       sessionsForDay: @escaping (SessionDayPlanner.Day) -> [ActivitySession]?,
       calendar: @escaping () -> Calendar = { .current },
       now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
    self.database = database
    self.generator = generator
    self.appTime = appTime
    self.sessionsForDay = sessionsForDay
    ledgers = ActivityLedgerStore(database: database, sessionsForDay: sessionsForDay, now: now)
    self.calendar = calendar
    self.now = now
  }

  /// The stored summary of exactly this range. Never starts generation; nil when the vault is locked.
  func summary(fromMs: Int64, toMs: Int64, currentModel: String?) -> StoredState? {
    let found: StoredRangeSummary?
    do {
      found = try database.read { DB.rangeSummary(startMs: fromMs, endMs: toMs, db: $0) }
    } catch {
      return nil
    }
    guard let stored = found else { return StoredState.none }
    let outdated = stored.promptVersion != SummaryPrompt.version || (currentModel != nil && stored.model != currentModel)
    return .stored(stored, outdated: outdated)
  }

  /// Runs the model for this range, one request at a time. A second request for the same range joins
  /// the first. A request from the user stops a `background` one, which reports `.cancelled`.
  /// `completion` runs on a background queue.
  func generateSummary(fromMs: Int64, toMs: Int64, model: String, background: Bool = false, completion: @escaping (Result) -> Void) {
    let range = appTime.resolve(fromMs: fromMs, toMs: toMs)
    let key = Key(fromMs: range.fromMs, toMs: range.toMs, model: model)
    lock.lock()
    if waiting[key] != nil {
      let promote = !background && backgroundKey == key
      if promote {
        backgroundPreempted = true
        backgroundKey = nil
        foregroundPromotions.insert(key)
      }
      waiting[key]?.append(completion)
      lock.unlock()
      if promote { generator.cancel() }
      return
    }
    waiting[key] = [completion]
    let epoch = lockEpoch
    var preempting = false
    if background {
      backgroundKey = key
      backgroundPreempted = false
    } else if backgroundKey != nil {
      backgroundPreempted = true
      preempting = true
    }
    lock.unlock()
    if preempting { generator.cancel() }

    queue.async { [self] in
      let isWanted = { self.isCurrent(epoch) && !(background && self.isBackgroundPreempted()) }
      var result = isWanted() ? generate(range: range, model: model, isWanted: isWanted) : .cancelled
      if background, takeForegroundPromotion(for: key), isCurrent(epoch) {
        result = generate(range: range, model: model, isWanted: { self.isCurrent(epoch) })
      }
      lock.lock()
      let completions = waiting.removeValue(forKey: key) ?? []
      if backgroundKey == key { backgroundKey = nil }
      lock.unlock()
      completions.forEach { $0(result) }
    }
  }

  /// Frees the model's memory after a background batch, unless a request is waiting to use it.
  func unloadModel(_ model: String) {
    queue.async { [self] in
      lock.lock()
      let idle = waiting.isEmpty
      lock.unlock()
      if idle { generator.unload(model: model) }
    }
  }

  /// Stops the running request and discards anything still in progress.
  func cancelRunning() {
    lock.lock()
    lockEpoch += 1
    lock.unlock()
    generator.cancel()
  }

  private func isCurrent(_ epoch: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return lockEpoch == epoch
  }

  private func isBackgroundPreempted() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return backgroundPreempted
  }

  private func takeForegroundPromotion(for key: Key) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return foregroundPromotions.remove(key) != nil
  }

  // MARK: - On `queue`

  private func generate(range: ResolvedSummaryRange, model: String, isWanted: () -> Bool) -> Result {
    guard !range.isEmpty else { return .noActivity }
    let contextTokens: Int
    switch generator.readiness(model: model) {
    case .ready(let limit): contextTokens = SummaryPrompt.contextTokens(modelLimit: limit)
    case .ollamaUnavailable: return .ollamaUnavailable
    case .modelNotInstalled: return .modelNotInstalled
    case .modelUnsuitable: return .modelUnsuitable
    case .cloudModelRefused: return .cloudModelRefused
    }

    // Read first: anything deleted from here on must stop this result from being stored.
    guard let (expected, stored) = try? database.read({ db in
      (DB.summaryInvalidationCount(db: db), DB.rangeSummaries(insideFromMs: range.fromMs, toMs: range.toMs, db: db))
    }) else { return .vaultLocked }
    let plan = RangeSummaryPlanner.plan(fromMs: range.fromMs, toMs: range.toMs, stored: stored)

    let length = SummaryPrompt.Length(rangeMs: range.toMs - range.fromMs)
    let budget = SummaryPrompt.inputBudgetBytes(contextTokens: contextTokens, maxOutputTokens: length.maxOutputTokens)
    let label = RangeLabeler(calendar: calendar(), range: range)
    let input = range.toMs - range.fromMs <= SummaryBuckets.detailedLimitMs
      ? detailedInput(plan: plan, budget: budget, label: label, isWanted: isWanted)
      : briefingInput(range: range, plan: plan, budget: budget, label: label, isWanted: isWanted)
    guard let input else { return isWanted() ? .vaultLocked : .cancelled }
    guard !input.isEmpty else { return .noActivity }

    let prompt = SummaryPrompt.prompt(rangeLabel: label.period(fromMs: range.fromMs, toMs: range.toMs),
                                      apps: appTime.report(fromMs: range.fromMs, toMs: range.toMs, topK: 10),
                                      earlierSummaries: input.earlier, activity: input.activity)
    guard isWanted() else { return .cancelled }
    let generated = generator.generate(model: model, system: SummaryPrompt.system(length: length), prompt: prompt,
                                       contextTokens: contextTokens, maxOutputTokens: length.maxOutputTokens)
    guard isWanted() else { return .cancelled }
    guard let generated, !generated.isEmpty else { return .failed }

    return finish(text: generated, range: range, model: model, expectedInvalidations: expected)
  }

  private struct Input {
    let earlier: [(label: String, text: String)]
    let activity: String

    var isEmpty: Bool { earlier.isEmpty && activity.isEmpty }
  }

  /// Short ranges: stored summaries inside the range, and raw session text for the rest.
  private func detailedInput(plan: RangeSummaryPlanner.Plan, budget: Int, label: RangeLabeler, isWanted: () -> Bool) -> Input? {
    guard let sessions = sessions(in: plan.gaps, isWanted: isWanted) else { return nil }
    let summariesBudget = plan.reused.isEmpty ? 0 : RangeSummaryPlanner.summariesBudgetBytes(total: budget, hasGaps: !plan.gaps.isEmpty)
    let earlier = plan.reused.map { summary in
      (label: label.period(fromMs: summary.startMs, toMs: summary.endMs),
       text: SummaryOutput.trim(summary.text, toBytes: summariesBudget / plan.reused.count))
    }
    let allocations = withEmbeddingRepresentatives(
      RepresentativeTextSelector.allocate(sessions: sessions, budgetBytes: budget - summariesBudget), isWanted: isWanted)
    let textIds = allocations.flatMap { $0.session.representativeTextIds }
    guard let texts = try? database.texts(ids: textIds) else { return nil }
    return Input(earlier: earlier, activity: RepresentativeTextSelector.render(allocations, texts: texts, timeLabel: label.time))
  }

  /// Long ranges: one section per calendar period, with its ledger and any stored summaries.
  private func briefingInput(range: ResolvedSummaryRange, plan: RangeSummaryPlanner.Plan, budget: Int,
                             label: RangeLabeler, isWanted: () -> Bool) -> Input? {
    let days = SessionDayPlanner.days(from: range.fromMs, to: range.toMs - 1, calendar: calendar())
    guard let dayLedgers = ledgers.ledgers(days: days, fromMs: range.fromMs, toMs: range.toMs, shouldContinue: isWanted) else { return nil }
    let sections = SummaryBuckets.buckets(fromMs: range.fromMs, toMs: range.toMs, calendar: calendar()).map { bucket in
      let inside = dayLedgers.filter { bucket.contains($0.startMs) }
      let summaries = plan.reused.filter { bucket.contains($0.startMs) }.map { summary in
        (label: label.period(fromMs: summary.startMs, toMs: summary.endMs), text: summary.text)
      }
      return RangeBriefing.Section(label: label.period(fromMs: bucket.lowerBound, toMs: bucket.upperBound),
                                   ledger: ActivityLedgerMerger.merge(inside, startMs: bucket.lowerBound, endMs: bucket.upperBound),
                                   summaries: summaries)
    }
    return Input(earlier: [], activity: RangeBriefing.render(sections, budgetBytes: budget))
  }

  private func finish(text: String, range: ResolvedSummaryRange, model: String, expectedInvalidations: Int64) -> Result {
    let nowMs = now()
    do {
      if RangeSummaryPlanner.isStorable(fromMs: range.fromMs, toMs: range.toMs, nowMs: nowMs, calendar: calendar()) {
        let summary = StoredRangeSummary(startMs: range.fromMs, endMs: range.toMs, model: model,
                                         promptVersion: SummaryPrompt.version, text: text, createdAtMs: nowMs)
        let stored = try database.write { try DB.storeRangeSummary(summary, expectedInvalidations: expectedInvalidations, db: $0) }
        return stored ? .generated(text: text, stored: true) : .discarded
      }
      let unchanged = try database.read { DB.summaryInvalidationCount(db: $0) == expectedInvalidations }
      return unchanged ? .generated(text: text, stored: false) : .discarded
    } catch {
      return .vaultLocked
    }
  }

  /// Uses stored embeddings where a session has them, and keeps its keyword choice where it doesn't.
  /// One read per session, so the timeline's reads can interleave.
  private func withEmbeddingRepresentatives(_ allocations: [RepresentativeTextSelector.Allocation], isWanted: () -> Bool) -> [RepresentativeTextSelector.Allocation] {
    allocations.map { allocation in
      guard isWanted() else { return allocation }
      var session = allocation.session
      let found = try? database.read { DB.sessionEmbeddingCandidates(fromMs: session.startMs, throughMs: session.endMs, db: $0) }
      guard let found, let chosen = EmbeddingRepresentativeSelector.representatives(from: found) else { return allocation }
      session.representativeTextIds = chosen
      return .init(session: session, excerptBytes: allocation.excerptBytes)
    }
  }

  /// Sessions overlapping the gaps, a day at a time so the timeline's session reads can interleave.
  private func sessions(in gaps: [Range<Int64>], isWanted: () -> Bool) -> [ActivitySession]? {
    var seen = Set<Int64>()
    var result: [ActivitySession] = []
    for gap in gaps {
      for day in SessionDayPlanner.days(from: gap.lowerBound, to: gap.upperBound - 1, calendar: calendar()) {
        guard isWanted(), let sessions = sessionsForDay(day) else { return nil }
        for session in sessions where session.endMs >= gap.lowerBound && session.startMs < gap.upperBound && seen.insert(session.id).inserted {
          result.append(session)
        }
      }
    }
    return result
  }
}
