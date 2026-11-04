import Foundation

enum SummaryModelReadiness: Equatable {
  /// `contextTokens` is the model's own limit, when it reports one.
  case ready(contextTokens: Int?)
  case ollamaUnavailable
  case modelNotInstalled
  /// Installed, but it can't generate text.
  case modelUnsuitable
  /// Hosted off this Mac, so screen text must not go to it.
  case cloudModelRefused
}

/// Generates summary text. All calls block except `cancel`.
protocol SummaryTextGenerating: AnyObject {
  func readiness(model: String) -> SummaryModelReadiness
  func generate(model: String, system: String, prompt: String, contextTokens: Int, maxOutputTokens: Int) -> String?
  /// Cancels a running `generate`, from any thread.
  func cancel()
  /// Frees the model's memory. Blocks.
  func unload(model: String)
}
