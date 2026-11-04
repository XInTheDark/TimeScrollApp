import Foundation

/// Text generation through the local Ollama server. Blocking; callers run on background queues.
/// Prompts hold screen text: they go only to this server, and are never logged.
final class OllamaTextGenerator: SummaryTextGenerating, @unchecked Sendable {
  struct ModelInfo: Equatable {
    let capabilities: [String]
    let contextTokens: Int?
    /// Set by Ollama for models that run on another host.
    let isRemote: Bool

    var canThink: Bool { capabilities.contains { $0.lowercased() == "thinking" } }
  }

  private static let showTimeout: TimeInterval = 5
  /// Nothing arrives until the whole summary is done, and the model may have to load first.
  private static let generateTimeout: TimeInterval = 600
  /// Long enough to reuse the model between requests, short enough not to hold its memory.
  private static let keepAlive = "1m"

  private let baseURL: String
  private let lock = NSLock()
  private var task: URLSessionTask?
  private var cancelled = false

  init(baseURL: String = "http://localhost:11434") {
    self.baseURL = baseURL
  }

  /// Installed models that can generate summaries; nil when Ollama could not be reached.
  func suitableModels() -> [String]? {
    guard let names = OllamaEmbeddingProvider.fetchModelNames(baseURL: baseURL, label: "list summary models") else { return nil }
    return names.filter {
      guard !Self.isCloudModelName($0), let info = modelInfo($0) else { return false }
      return Self.classify(info) == .ready(contextTokens: info.contextTokens)
    }
  }

  func readiness(model: String) -> SummaryModelReadiness {
    if Self.isCloudModelName(model) { return .cloudModelRefused }
    guard let names = OllamaEmbeddingProvider.fetchModelNames(baseURL: baseURL, label: "check summary model") else { return .ollamaUnavailable }
    guard names.contains(model) || names.contains("\(model):latest") else { return .modelNotInstalled }
    guard let info = modelInfo(model) else { return .ollamaUnavailable }
    return Self.classify(info)
  }

  func generate(model: String, system: String, prompt: String, contextTokens: Int, maxOutputTokens: Int) -> String? {
    guard let url = URL(string: "\(baseURL)/api/generate") else { return nil }
    lock.lock()
    cancelled = false
    lock.unlock()
    let payload = Self.generatePayload(model: model, system: system, prompt: prompt, contextTokens: contextTokens,
                                       maxOutputTokens: maxOutputTokens, keepAlive: Self.keepAlive,
                                       modelThinks: modelInfo(model)?.canThink ?? false)
    let data = OllamaSyncRequest.postJSON(url, payload: payload, timeout: Self.generateTimeout, label: "generate summary") { [self] task in
      lock.lock()
      self.task = task
      let alreadyCancelled = cancelled
      lock.unlock()
      if alreadyCancelled { task.cancel() }
    }
    lock.lock()
    task = nil
    lock.unlock()
    return data.flatMap(Self.parseGeneratedText)
  }

  /// Frees the model's memory now instead of when its keep-alive ends.
  func unload(model: String) {
    guard let url = URL(string: "\(baseURL)/api/generate") else { return }
    _ = OllamaSyncRequest.postJSON(url, payload: ["model": model, "keep_alive": 0], timeout: Self.showTimeout, label: "unload summary model")
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let running = task
    lock.unlock()
    running?.cancel()
  }

  private func modelInfo(_ model: String) -> ModelInfo? {
    guard let url = URL(string: "\(baseURL)/api/show"),
          let data = OllamaSyncRequest.postJSON(url, payload: ["model": model], timeout: Self.showTimeout, label: "inspect summary model") else {
      return nil
    }
    return Self.parseModelInfo(data)
  }

  // MARK: - Pure

  /// Ollama cloud models are tagged `:cloud` or `<size>-cloud`.
  static func isCloudModelName(_ model: String) -> Bool {
    guard let tag = model.lowercased().split(separator: ":").last, model.contains(":") else { return false }
    return tag == "cloud" || tag.hasSuffix("-cloud")
  }

  /// Fails closed: a server that doesn't report text generation is not used.
  static func classify(_ info: ModelInfo) -> SummaryModelReadiness {
    if info.isRemote { return .cloudModelRefused }
    guard info.capabilities.contains(where: { $0.lowercased() == "completion" }) else { return .modelUnsuitable }
    return .ready(contextTokens: info.contextTokens)
  }

  static func parseModelInfo(_ data: Data) -> ModelInfo? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let remote = ["remote_host", "remote_model"].contains { !((json[$0] as? String) ?? "").isEmpty }
    let context = (json["model_info"] as? [String: Any])?
      .first { $0.key.hasSuffix(".context_length") }
      .flatMap { ($0.value as? NSNumber)?.intValue }
    return ModelInfo(capabilities: json["capabilities"] as? [String] ?? [], contextTokens: context, isRemote: remote)
  }

  static func generatePayload(model: String, system: String, prompt: String, contextTokens: Int,
                              maxOutputTokens: Int, keepAlive: String, modelThinks: Bool) -> [String: Any] {
    var payload: [String: Any] = [
      "model": model,
      "system": system,
      "prompt": prompt,
      "stream": false,
      "keep_alive": keepAlive,
      // Set explicitly: Ollama cuts input that doesn't fit the context, without an error.
      "options": ["num_ctx": contextTokens, "num_predict": maxOutputTokens],
      // Without it, a small model can write its reasoning, or obey screen text, in the answer.
      "format": SummaryOutput.jsonSchema,
    ]
    // Thinking counts against the output limit, and can use all of it before any summary is written.
    if modelThinks { payload["think"] = false }
    return payload
  }

  /// Nil when empty, malformed, or cut off at the output limit, so a half-finished summary is never stored.
  static func parseGeneratedText(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["done_reason"] as? String != "length",
          let response = (json["response"] as? String)?.data(using: .utf8),
          let answer = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return nil }
    return SummaryOutput.text(fromAnswer: answer)
  }
}
