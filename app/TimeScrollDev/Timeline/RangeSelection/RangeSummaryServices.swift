import Foundation

/// What the summary panel needs from the rest of the app. All of it runs off the main thread.
struct RangeSummaryServices: Sendable {
  var report: @Sendable (TimelineRange) async -> AppTimeReport?
  var stored: @Sendable (TimelineRange, String?) async -> RangeSummaryProvider.StoredState?
  var models: @Sendable () async -> [String]?
  var generate: @Sendable (TimelineRange, String) async -> RangeSummaryProvider.Result
  var cancel: @Sendable () -> Void
  var savedModel: @Sendable () -> String?
  var saveModel: @Sendable (String) -> Void

  static let modelKey = "summaries.model"
  private static let topApps = 8

  static let live = RangeSummaryServices(
    report: { range in
      await background { AppTimeProvider.shared.report(fromMs: range.fromMs, toMs: range.toMs, topK: topApps) }
    },
    stored: { range, model in
      await background { RangeSummaryProvider.shared.summary(fromMs: range.fromMs, toMs: range.toMs, currentModel: model) }
    },
    models: {
      #if DEBUG
      if DemoMode.isActive { return DemoMode.summaryModels }
      #endif
      return await background { OllamaTextGenerator().suitableModels() }
    },
    generate: { range, model in
      await withCheckedContinuation { continuation in
        RangeSummaryProvider.shared.generateSummary(fromMs: range.fromMs, toMs: range.toMs, model: model) {
          continuation.resume(returning: $0)
        }
      }
    },
    cancel: { RangeSummaryProvider.shared.cancelRunning() },
    savedModel: {
      let defaults = UserDefaults.standard
      if let picked = defaults.string(forKey: modelKey) { return picked }
      return defaults.string(forKey: BackgroundSummaryRunner.modelKey).flatMap { $0.isEmpty ? nil : $0 }
    },
    saveModel: { UserDefaults.standard.set($0, forKey: modelKey) })

  private static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
  }
}
