import CoreVideo
import Foundation

// Ollama provider: text embeddings for any embedding model, plus screenshot embeddings for
// multimodal models whose `/api/show` capabilities include "vision".
final class OllamaEmbeddingProvider {
    typealias MetadataFetcher = (_ model: String, _ baseURL: String) -> Int?

    var dim: Int
    let model: String
    private let baseURL: String
    private let capabilities: OllamaModelCapabilities
    private static let defaultDim = 384
    private static let embedRequestTimeout: TimeInterval = 12
    private static let imageEmbedRequestTimeout: TimeInterval = 30
    private static let metadataRequestTimeout: TimeInterval = 5
    private static let listRequestTimeout: TimeInterval = 5
    /// Extracted text sent alongside an image is capped like a single text chunk.
    private static let maxImageCompanionTextLength = 2_000
    private static let metadataQueue = DispatchQueue(label: "com.timescroll.ollama.metadata", attributes: .concurrent)
    private static var dimCache: [String: Int] = [:]
    private static let dimDefaultsKey = "embedding.ollamaDims"
    private static var hasLoadedCache = false

    init(model: String,
         baseURL: String = "http://localhost:11434",
         eagerlyResolveDimension: Bool = true,
         metadataFetcher: @escaping MetadataFetcher = OllamaEmbeddingProvider.fetchEmbeddingLength,
         capabilities: OllamaModelCapabilities = .shared) {
        self.model = model
        self.baseURL = baseURL
        self.capabilities = capabilities
        if let cached = Self.cachedDim(for: model) {
            self.dim = cached
        } else if eagerlyResolveDimension, let fetched = metadataFetcher(model, baseURL) {
            self.dim = fetched
            Self.storeDim(fetched, for: model)
        } else {
            self.dim = Self.defaultDim
        }
    }

    /// True when the model embeds images. Never blocks: unknown models are checked in the background.
    var supportsImageInput: Bool {
        capabilities.supportsImages(model: model, baseURL: baseURL)
    }

    /// Re-reads the model's capabilities from Ollama (blocking); call off the main thread.
    func refreshImageSupport() {
        capabilities.refresh(model: model, baseURL: baseURL)
    }

    private func effectiveText(for text: String, usage: EmbeddingService.Usage) -> String {
        let m = model.lowercased()
        // embeddinggemma specific prefixes
        if m.contains("gemma") && m.contains("embed") {
             switch usage {
             case .query: return "task: search result | query: \(text)"
             case .document: return "title: none | text: \(text)"
             }
        }
        return text
    }

    func embed(text: String) -> [Float] { embedWithStats(text: text).0 }

    func embedWithStats(text: String, usage: EmbeddingService.Usage = .document) -> ([Float], Int, Int) {
        let textToEmbed = effectiveText(for: text, usage: usage)
        let tokens = textToEmbed.split(separator: " ").count

        // Synchronous request (will block)
        guard let result = requestEmbedding(input: textToEmbed,
                                            timeout: Self.embedRequestTimeout,
                                            label: "embed") else {
            return (Array(repeating: 0, count: dim), 0, tokens)
        }
        return (result, tokens, tokens)
    }

    /// Embeds a screenshot, optionally together with its extracted text as one joint input.
    /// Returns an empty vector when the request fails so callers can fall back to text.
    func embedImageDocument(pixelBuffer: CVPixelBuffer, extractedText: String?) -> [Float] {
        guard let image = OllamaImageEncoder.base64JPEG(from: pixelBuffer) else {
            print("[Ollama] Failed to encode image for embedding")
            return []
        }
        var item: [String: Any] = ["image": image]
        if let extractedText, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let companion = String(extractedText.prefix(Self.maxImageCompanionTextLength))
            item["text"] = effectiveText(for: companion, usage: .document)
        }
        return requestEmbedding(input: [item],
                                timeout: Self.imageEmbedRequestTimeout,
                                label: "embed image") ?? []
    }

    private func requestEmbedding(input: Any, timeout: TimeInterval, label: String) -> [Float]? {
        guard let url = URL(string: "\(baseURL)/api/embed") else {
            print("[Ollama] Invalid URL")
            return nil
        }
        let payload: [String: Any] = [
            "model": model,
            "input": input
        ]
        guard let data = OllamaSyncRequest.postJSON(url, payload: payload, timeout: timeout, label: label) else {
            return nil
        }
        guard let result = Self.parseEmbedding(from: data) else {
            print("[Ollama] No embeddings in response")
            return nil
        }
        // If Ollama returned a different dimension than we expected, update in-memory dim and cache it.
        if result.count != dim {
            dim = result.count
            Self.storeDim(result.count, for: model)
        }
        return result
    }

    /// Ollama /api/embed returns {"model": "...", "embeddings": [[...], ...]}; a single input yields one vector.
    static func parseEmbedding(from data: Data) -> [Float]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let embeddings = json["embeddings"] as? [[Double]],
           let embedding = embeddings.first, !embedding.isEmpty {
            return embedding.map { Float($0) }
        }
        if let embedding = json["embedding"] as? [Double], !embedding.isEmpty {
            // Fallback for older API format
            return embedding.map { Float($0) }
        }
        return nil
    }


    // Check if model is installed
    static func isModelInstalled(_ model: String, baseURL: String = "http://localhost:11434") -> Bool {
        fetchModelNames(baseURL: baseURL, label: "check installed models")?
            .contains { $0.hasPrefix(model) } ?? false
    }

    /// Names reported by `/api/tags`; nil when Ollama could not be reached (as opposed to no models).
    static func fetchModelNames(baseURL: String = "http://localhost:11434", label: String = "list models") -> [String]? {
        guard let url = URL(string: "\(baseURL)/api/tags"),
              let data = OllamaSyncRequest.get(url, timeout: listRequestTimeout, label: label) else {
            return nil
        }
        return parseModelsFromData(data)
    }

    // Exposed parser used by listModels and tests
    static func parseModelsFromData(_ data: Data) -> [String] {
        var out: [String] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for obj in arr {
                if let name = obj["name"] as? String { out.append(name) }
                if let id = obj["id"] as? String { out.append(id) }
            }
            return out
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let models = obj["models"] as? [[String: Any]] {
                for m in models { if let name = m["name"] as? String { out.append(name) } }
            }
            return out
        }
        return out
    }

    /// Models to offer in settings, embedding models first-class when any exist.
    /// nil when Ollama could not be reached, so callers can retry instead of caching an empty list.
    static func listModels(baseURL: String = "http://localhost:11434") -> [String]? {
        guard let names = fetchModelNames(baseURL: baseURL) else { return nil }
        let uniq = Array(NSOrderedSet(array: names)) as? [String] ?? names
        let embedOnly = uniq.filter { $0.lowercased().contains("embed") }
        return embedOnly.isEmpty ? uniq : embedOnly
    }

    // Pull model from Ollama
    static func pullModel(_ model: String, baseURL: String = "http://localhost:11434", completion: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/pull") else {
            completion(false, "Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["model": model]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false, "Failed to serialize request")
            return
        }
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(true, nil)
            } else {
                completion(false, "HTTP error")
            }
        }.resume()
    }

    // MARK: - Model metadata helpers

    private static func cachedDim(for model: String) -> Int? {
        ensureDimCacheLoaded()
        return metadataQueue.sync { dimCache[model] }
    }

    static func cachedOrDefaultDim(for model: String) -> Int {
        cachedDim(for: model) ?? defaultDim
    }

    private static func storeDim(_ dim: Int, for model: String) {
        metadataQueue.sync(flags: .barrier) {
            dimCache[model] = dim
            persistDimCacheLocked()
        }
    }

    private static func persistDimCacheLocked() {
        UserDefaults.standard.set(dimCache, forKey: dimDefaultsKey)
    }

    private static func ensureDimCacheLoaded() {
        metadataQueue.sync(flags: .barrier) {
            guard !hasLoadedCache else { return }
            hasLoadedCache = true
            guard let stored = UserDefaults.standard.dictionary(forKey: dimDefaultsKey) else {
                dimCache = [:]
                return
            }
            var parsed: [String: Int] = [:]
            for (key, value) in stored {
                if let intVal = value as? Int {
                    parsed[key] = intVal
                } else if let numVal = value as? NSNumber {
                    parsed[key] = numVal.intValue
                } else if let strVal = value as? String, let intVal = Int(strVal) {
                    parsed[key] = intVal
                }
            }
            dimCache = parsed
        }
    }

#if DEBUG
    static func clearCachedDimsForTesting(preserveDefaults: Bool = false) {
        metadataQueue.sync(flags: .barrier) {
            dimCache = [:]
            hasLoadedCache = false
            if !preserveDefaults {
                UserDefaults.standard.removeObject(forKey: dimDefaultsKey)
            }
        }
    }
#endif

    private static func fetchEmbeddingLength(model: String, baseURL: String) -> Int? {
        guard let url = URL(string: "\(baseURL)/api/show"),
              let data = OllamaSyncRequest.postJSON(url,
                                                    payload: ["name": model],
                                                    timeout: metadataRequestTimeout,
                                                    label: "fetch embedding metadata") else {
            return nil
        }
        return parseEmbeddingLength(from: data)
    }

    static func parseEmbeddingLength(from data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parseEmbeddingLength(from: json)
    }

    private static func parseEmbeddingLength(from json: Any) -> Int? {
        if let dict = json as? [String: Any] {
            if let direct = extractLength(from: dict) { return direct }
            if let details = dict["details"] {
                if let len = parseEmbeddingLength(from: details) { return len }
            }
            if let info = dict["model_info"] {
                if let len = parseEmbeddingLength(from: info) { return len }
            }
        }
        return nil
    }

    private static func extractLength(from dict: [String: Any]) -> Int? {
        let candidateKeys = ["dim", "embedding_length", "hidden_size", "bert.embedding_length", "general.embedding_length"]
        for key in candidateKeys {
            if let value = dict[key] {
                if let intVal = value as? Int { return intVal }
                if let strVal = value as? String, let intVal = Int(strVal) { return intVal }
            }
        }
        return nil
    }
}
