import Foundation

/// Tracks which Ollama models accept image input, as reported by `/api/show` `capabilities`
/// (multimodal embedding models advertise `["embedding", "vision", ...]`).
/// Answers come from a persisted cache so capture never waits on the network; unknown models
/// are looked up in the background and treated as text-only until the answer arrives.
final class OllamaModelCapabilities {
    typealias Fetcher = (_ model: String, _ baseURL: String) -> [String]?

    static let shared = OllamaModelCapabilities()

    private static let defaultsKey = "embedding.ollamaImageSupport"
    private static let requestTimeout: TimeInterval = 5
    private static let retryInterval: TimeInterval = 60

    private let lock = NSLock()
    private let fetcher: Fetcher
    private let defaults: UserDefaults
    private var imageSupport: [String: Bool]
    private var inFlight: Set<String> = []
    private var lastFailure: [String: Date] = [:]
    private let queue = DispatchQueue(label: "com.timescroll.ollama.capabilities", qos: .utility)

    init(defaults: UserDefaults = .standard, fetcher: @escaping Fetcher = OllamaModelCapabilities.fetchCapabilities) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.imageSupport = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool]) ?? [:]
    }

    /// Cached answer; schedules a background lookup when the model has not been checked yet.
    func supportsImages(model: String, baseURL: String = "http://localhost:11434") -> Bool {
        lock.lock()
        let cached = imageSupport[model]
        lock.unlock()
        if let cached { return cached }
        refreshInBackground(model: model, baseURL: baseURL)
        return false
    }

    /// Blocking lookup that updates the cache. Returns nil when Ollama could not be reached.
    @discardableResult
    func refresh(model: String, baseURL: String = "http://localhost:11434") -> Bool? {
        guard let capabilities = fetcher(model, baseURL) else {
            lock.lock()
            lastFailure[model] = Date()
            lock.unlock()
            return nil
        }
        let supported = Self.supportsImageInput(capabilities)
        lock.lock()
        imageSupport[model] = supported
        lastFailure[model] = nil
        defaults.set(imageSupport, forKey: Self.defaultsKey)
        lock.unlock()
        return supported
    }

    private func refreshInBackground(model: String, baseURL: String) {
        lock.lock()
        let recentlyFailed = lastFailure[model].map { Date().timeIntervalSince($0) < Self.retryInterval } ?? false
        guard !inFlight.contains(model), !recentlyFailed else {
            lock.unlock()
            return
        }
        inFlight.insert(model)
        lock.unlock()

        queue.async { [self] in
            refresh(model: model, baseURL: baseURL)
            lock.lock()
            inFlight.remove(model)
            lock.unlock()
        }
    }

    static func supportsImageInput(_ capabilities: [String]) -> Bool {
        capabilities.contains { ["vision", "image"].contains($0.lowercased()) }
    }

    /// Parses the `capabilities` list from an `/api/show` response; nil when the field is absent.
    static func parseCapabilities(from data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["capabilities"] as? [String]
    }

    static func fetchCapabilities(model: String, baseURL: String) -> [String]? {
        guard let url = URL(string: "\(baseURL)/api/show"),
              let data = OllamaSyncRequest.postJSON(url,
                                                    payload: ["model": model],
                                                    timeout: requestTimeout,
                                                    label: "fetch model capabilities") else {
            return nil
        }
        // Older Ollama servers omit `capabilities`; they cannot embed images either.
        return parseCapabilities(from: data) ?? []
    }
}
