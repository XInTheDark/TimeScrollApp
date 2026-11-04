import Foundation

/// The summary panel's state for one range. Opening it reads stats and any stored summary; the model
/// only runs when the user asks. Results for an earlier range are ignored.
@MainActor
final class RangeSummaryPanelModel: ObservableObject {
  enum Stats: Equatable {
    case loading
    case loaded(AppTimeReport)
    case unavailable
  }

  enum Models: Equatable {
    case loading
    case ollamaUnavailable
    case loaded([String])
  }

  enum Problem: Equatable {
    case ollamaUnavailable, noModels, chooseModel, modelNotInstalled, modelUnsuitable, cloudModelRefused
    case failed, discarded, noActivity, vaultLocked
  }

  enum Summary: Equatable {
    case idle
    case generating
    /// `savedModel` and `createdAtMs` are set for a saved summary. `isOutdated` means an older prompt
    /// wrote it; the caption already names the model, so another model doesn't count.
    case text(String, savedModel: String?, createdAtMs: Int64?, isOutdated: Bool)
    case problem(Problem)
  }

  @Published private(set) var stats = Stats.loading
  @Published private(set) var models = Models.loading
  @Published private(set) var summary = Summary.idle
  @Published private(set) var selectedModel: String?

  private let services: RangeSummaryServices
  private var range: TimelineRange?
  private var generation = 0
  private var isRunning = false
  private var tasks: [Task<Void, Never>] = []

  init(services: RangeSummaryServices = .live) {
    self.services = services
    selectedModel = services.savedModel()
  }

  /// Shows `range`. With `generate`, also makes a summary if none is stored.
  func show(_ range: TimelineRange, generate: Bool) {
    guard range != self.range || generate else { return }
    let isNewRange = range != self.range
    if isNewRange { stopRunning() }
    self.range = range
    generation += 1
    let token = generation
    if isNewRange {
      stats = .loading
      summary = .idle
      track { [self] in
        let report = await services.report(range)
        guard self.range == range else { return }
        stats = report.map(Stats.loaded) ?? .unavailable
      }
    }
    if case .generating = summary { return }
    track { [self] in
      await refreshModels()
      guard token == generation else { return }
      if isNewRange || summaryIsMissing { await showStored(token: token) }
      guard token == generation else { return }
      if generate, summaryIsMissing { startGenerating() }
    }
  }

  /// Runs the model even if a stored summary exists.
  func regenerate() {
    startGenerating()
  }

  func cancelGenerating() {
    guard case .generating = summary else { return }
    generation += 1
    stopRunning()
    summary = .idle
  }

  func select(model: String) {
    selectedModel = model
    services.saveModel(model)
  }

  /// Retries after the user fixes a problem, such as starting Ollama.
  func retry() {
    generation += 1
    let token = generation
    summary = .idle
    track { [self] in
      await refreshModels()
      guard token == generation else { return }
      startGenerating()
    }
  }

  /// Stops any request and forgets the text, which may be from the vault.
  func close() {
    generation += 1
    stopRunning()
    range = nil
    stats = .loading
    summary = .idle
  }

  /// Waits for the work started so far; for tests.
  func settle() async {
    while !tasks.isEmpty {
      let running = tasks
      tasks = []
      for task in running { await task.value }
    }
  }

  private var summaryIsMissing: Bool {
    switch summary {
    case .idle, .problem: return true
    case .generating, .text: return false
    }
  }

  private func track(_ work: @escaping @MainActor () async -> Void) {
    tasks.removeAll { $0.isCancelled }
    if tasks.count > 16 { tasks.removeFirst(tasks.count - 16) }
    tasks.append(Task { @MainActor in await work() })
  }

  private func stopRunning() {
    if isRunning { services.cancel() }
    isRunning = false
  }

  private func refreshModels() async {
    let found = await services.models()
    guard let found else {
      models = .ollamaUnavailable
      return
    }
    models = .loaded(found)
    if selectedModel.map({ !Self.contains(found, $0) }) ?? true {
      // Only an unambiguous choice is made for the user.
      selectedModel = found.count == 1 ? found[0] : nil
    }
  }

  private func showStored(token: Int) async {
    guard let range else { return }
    let state = await services.stored(range, selectedModel)
    guard token == generation else { return }
    switch state {
    case .stored(let stored, _):
      summary = .text(stored.text, savedModel: stored.model, createdAtMs: stored.createdAtMs,
                      isOutdated: stored.promptVersion != SummaryPrompt.version)
    case .some(.none), nil:
      break
    }
  }

  private func startGenerating() {
    guard let range else { return }
    switch models {
    case .ollamaUnavailable:
      summary = .problem(.ollamaUnavailable)
      return
    case .loaded(let names) where names.isEmpty:
      summary = .problem(.noModels)
      return
    case .loading, .loaded:
      break
    }
    guard let model = selectedModel else {
      summary = .problem(.chooseModel)
      return
    }
    generation += 1
    let token = generation
    summary = .generating
    isRunning = true
    track { [self] in
      let result = await services.generate(range, model)
      guard token == generation else { return }
      isRunning = false
      apply(result, model: model)
    }
  }

  private func apply(_ result: RangeSummaryProvider.Result, model: String) {
    switch result {
    case .generated(let text, let stored):
      summary = .text(text, savedModel: stored ? model : nil, createdAtMs: stored ? Int64(Date().timeIntervalSince1970 * 1000) : nil, isOutdated: false)
    case .noActivity: summary = .problem(.noActivity)
    case .ollamaUnavailable: summary = .problem(.ollamaUnavailable)
    case .modelNotInstalled: summary = .problem(.modelNotInstalled)
    case .modelUnsuitable: summary = .problem(.modelUnsuitable)
    case .cloudModelRefused: summary = .problem(.cloudModelRefused)
    case .failed: summary = .problem(.failed)
    case .discarded: summary = .problem(.discarded)
    case .vaultLocked: summary = .problem(.vaultLocked)
    case .cancelled: summary = .idle
    }
  }

  private static func contains(_ names: [String], _ model: String) -> Bool {
    names.contains(model) || names.contains("\(model):latest")
  }
}
