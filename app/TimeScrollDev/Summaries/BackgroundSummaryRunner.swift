import Foundation

/// Fills in finished periods with the default summary model, when the system says it's a good time.
/// Does nothing until a model is chosen. Failures store nothing and affect nothing else.
final class BackgroundSummaryRunner: @unchecked Sendable {
  static let shared = BackgroundSummaryRunner()
  static let enabledKey = "settings.backgroundSummariesEnabled"
  static let modelKey = "settings.defaultSummaryModel"
  static let maxCallsPerRun = 12

  private let activity = NSBackgroundActivityScheduler(identifier: "com.muzhen.TimeScroll.backgroundSummaries")
  private let lock = NSLock()
  /// Periods with nothing to summarize, or that failed, until the next launch.
  private var skipped = Set<Range<Int64>>()

  func start() {
    activity.repeats = true
    activity.interval = 60 * 60
    activity.tolerance = 15 * 60
    activity.qualityOfService = .utility
    activity.schedule { [weak self] completion in
      guard let self else { return completion(.finished) }
      completion(self.run() ? .finished : .deferred)
    }
  }

  /// False if the system asked to wait.
  private func run() -> Bool {
    let defaults = UserDefaults.standard
    let enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
    guard enabled, let model = defaults.string(forKey: Self.modelKey), !model.isEmpty else { return true }

    var calls = 0
    defer { if calls > 0 { RangeSummaryProvider.shared.unloadModel(model) } }
    while calls < Self.maxCallsPerRun {
      if activity.shouldDefer { return false }
      let allowance = BackgroundSummaryConditions.current().allowance
      guard allowance != .none, let period = next(allowance: allowance) else { return true }
      calls += 1
      let result = generate(period, model: model)
      switch result {
      case .generated, .noActivity, .failed, .discarded:
        if Self.shouldSkipAfter(result) { insertSkipped(period) }
      case .ollamaUnavailable, .modelNotInstalled, .modelUnsuitable, .cloudModelRefused, .vaultLocked, .cancelled:
        return true
      }
    }
    return true
  }

  private func next(allowance: BackgroundSummaryConditions.Allowance) -> Range<Int64>? {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let earliest = nowMs - 70 * 86_400_000
    let database = SharedSummaryDatabase()
    guard let stored = try? database.read({ DB.rangeSummaries(insideFromMs: earliest, toMs: nowMs, db: $0) }) else { return nil }
    lock.lock()
    let skippedNow = skipped
    lock.unlock()
    return BackgroundSummaryPlanner.pending(nowMs: nowMs, calendar: .current,
                                            stored: Set(stored.map { $0.startMs..<$0.endMs }),
                                            skipped: skippedNow, allowance: allowance).first
  }

  private func insertSkipped(_ period: Range<Int64>) {
    lock.lock()
    skipped.insert(period)
    lock.unlock()
  }

  static func shouldSkipAfter(_ result: RangeSummaryProvider.Result) -> Bool {
    switch result {
    case .noActivity, .failed, .discarded: return true
    default: return false
    }
  }

  private func generate(_ period: Range<Int64>, model: String) -> RangeSummaryProvider.Result {
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox()
    RangeSummaryProvider.shared.generateSummary(fromMs: period.lowerBound, toMs: period.upperBound, model: model, background: true) { result in
      box.value = result
      done.signal()
    }
    done.wait()
    return box.value
  }

  private final class ResultBox: @unchecked Sendable {
    var value = RangeSummaryProvider.Result.cancelled
  }
}
