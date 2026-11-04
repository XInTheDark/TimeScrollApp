import Foundation

/// Installed summary models for a picker, listed off the main thread.
@MainActor
final class SummaryModelList: ObservableObject {
  enum State: Equatable {
    case loading
    case ollamaUnavailable
    case loaded([String])
  }

  @Published private(set) var state = State.loading

  func refresh() {
    state = .loading
    Task { [weak self] in
      let models = await Task.detached(priority: .userInitiated) { OllamaTextGenerator().suitableModels() }.value
      self?.state = models.map(State.loaded) ?? .ollamaUnavailable
    }
  }
}
