import Foundation
import NaturalLanguage

// Lightweight embedding service
// Supports multiple embedding providers:
// - Apple NaturalLanguage (word embeddings, averaged)
// - Ollama (snowflake-arctic-embed:33m and other models)
// All vectors are L2-normalized Float32 so dot(query, doc) ~ cosine.
final class EmbeddingService {
    static let shared = EmbeddingService()

    enum Provider: String, CaseIterable {
        case appleNL = "apple-nl"
        case ollama = "ollama"

        var displayName: String {
            switch self {
            case .appleNL: return "Apple built-in"
            case .ollama: return "Ollama"
            }
        }
    }

    private init() {
        let d = UserDefaults.standard
        aiEnabled = (d.object(forKey: "settings.aiEmbeddingsEnabled") != nil) ? d.bool(forKey: "settings.aiEmbeddingsEnabled") : false
        threshold = (d.object(forKey: "settings.aiThreshold") != nil) ? d.double(forKey: "settings.aiThreshold") : 0.5
        maxCandidates = {
            let v = d.integer(forKey: "settings.aiMaxCandidates")
            return v > 0 ? v : 10000
        }()

        // Load selected provider
        if let raw = d.string(forKey: "settings.embeddingProvider"), let p = Provider(rawValue: raw) {
            selectedProvider = p
        } else {
            selectedProvider = .appleNL
        }

        // Load selected model (if present) — default to the previous snowflake model for backwards compatibility
        if let m = d.string(forKey: "settings.embeddingModel") {
            selectedModel = m
        } else {
            selectedModel = "snowflake-arctic-embed:33m"
        }

        // Initialize the appropriate provider
        switch selectedProvider {
        case .appleNL:
            nlProvider = NLEmbeddingProvider()
            ollamaProvider = nil
        case .ollama:
            nlProvider = nil
            let model = selectedModel ?? "snowflake-arctic-embed:33m"
            ollamaProvider = OllamaEmbeddingProvider(model: model)
        }
    }

    private(set) var aiEnabled: Bool
    private(set) var threshold: Double
    private(set) var maxCandidates: Int
    private(set) var selectedProvider: Provider
    private(set) var selectedModel: String?

        private var nlProvider: NLEmbeddingProvider?
        private var ollamaProvider: OllamaEmbeddingProvider?

    var dim: Int {
        switch selectedProvider {
        case .appleNL: return nlProvider?.dim ?? 0
        case .ollama: return ollamaProvider?.dim ?? 0
        }
    }

    // Reload selection from UserDefaults — used after settings change
    func reloadFromSettings() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "settings.embeddingProvider"), let p = Provider(rawValue: raw) {
            selectedProvider = p
        } else {
            selectedProvider = .appleNL
        }
        if let m = d.string(forKey: "settings.embeddingModel") {
            selectedModel = m
        } else {
            selectedModel = "snowflake-arctic-embed:33m"
        }

        switch selectedProvider {
        case .appleNL:
            nlProvider = NLEmbeddingProvider()
            ollamaProvider = nil
        case .ollama:
            nlProvider = nil
            let model = selectedModel ?? "snowflake-arctic-embed:33m"
            ollamaProvider = OllamaEmbeddingProvider(model: model)
        }
    }

    var providerID: String { selectedProvider.rawValue }
    var modelID: String { selectedModel ?? selectedProvider.rawValue }

    func embed(_ text: String) -> [Float] {
        return embedWithStats(text).vec
    }

    func embedWithStats(_ text: String) -> (vec: [Float], known: Int, total: Int) {
        // If text is very long, break into multiple chunks and average embeddings.
        let (raw, known, total): ([Float], Int, Int)

        // Use provider-agnostic long-text embedding util when text exceeds a threshold.
        let maxInput = 2_000
        if text.count > maxInput {
            (raw, known, total) = Self.embedLongTextWithStats(text: text, maxInput: maxInput, maxChunks: 10, overlapPct: 0.10, provider: selectedProvider, nlProvider: nlProvider, ollamaProvider: ollamaProvider)
        } else {
            switch selectedProvider {
            case .appleNL:
                guard let p = nlProvider else { return ([], 0, 0) }
                (raw, known, total) = p.embedWithStats(text: text)
            case .ollama:
                guard let p = ollamaProvider else { return ([], 0, 0) }
                (raw, known, total) = p.embedWithStats(text: text)
            }
        }

        let dbg = UserDefaults.standard.bool(forKey: "settings.debugMode")
        if dbg {
            var sum: Float = 0; for x in raw { sum += x*x }
            let norm = sqrtf(sum)
            let head = raw.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
            let model = selectedModel ?? selectedProvider.rawValue
            print("[AI][Embed] provider=\(selectedProvider.rawValue) model=\(model) dim=\(raw.count) known=\(known)/\(total) norm=\(String(format: "%.4f", norm)) head=[\(head)]")
        }
        return (Self.l2normalize(raw), known, total)
    }

    static func l2normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let inv = (sum > 0) ? (1.0 / sqrtf(sum)) : 1.0
        if inv == 1.0 { return v }
        var out = v
        for i in 0..<out.count { out[i] *= inv }
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        var i = 0
        // unrolled for a tiny speed bump
        while i + 3 < n {
            s += a[i] * b[i] + a[i+1] * b[i+1] + a[i+2] * b[i+2] + a[i+3] * b[i+3]
            i += 4
        }
        while i < n { s += a[i] * b[i]; i += 1 }
        return s
    }

}

// MARK: - Long-text chunking + averaging
extension EmbeddingService {
    /// Chunk `text` into overlapping windows of up to `maxInput` characters with `overlapPct` overlap.
    /// Returns a sampled list of at most `maxChunks` windows centered around the middle of the text.
    static func chunkText(_ text: String, maxInput: Int = 2000, overlapPct: Double = 0.10, maxChunks: Int = 10) -> [String] {
        guard text.count > maxInput else { return [text] }
        let chars = Array(text)
        let total = chars.count
        let step = max(1, Int(Double(maxInput) * (1.0 - overlapPct)))

        var windows: [String] = []
        var i = 0
        while i < total {
            let end = min(i + maxInput, total)
            windows.append(String(chars[i..<end]))
            if end == total { break }
            i += step
        }

        guard windows.count > maxChunks else { return windows }

        // Sample around the middle window.
        let mid = windows.count / 2
        let half = maxChunks / 2
        var start = max(0, mid - half)
        // Ensure we capture exactly `maxChunks` windows if possible
        if start + maxChunks > windows.count { start = max(0, windows.count - maxChunks) }
        let end = min(windows.count, start + maxChunks)
        return Array(windows[start..<end])
    }

    /// Embed long text by splitting into chunks and averaging embeddings from a provider.
    /// This function is provider-agnostic and expects provider instances or nil when not applicable.
    static func embedLongTextWithStats(text: String,
                                       maxInput: Int = 2000,
                                       maxChunks: Int = 10,
                                       overlapPct: Double = 0.10,
                                       provider: Provider,
                                       nlProvider: NLEmbeddingProvider?,
                                       ollamaProvider: OllamaEmbeddingProvider?) -> ([Float], Int, Int) {
        let windows = chunkText(text, maxInput: maxInput, overlapPct: overlapPct, maxChunks: maxChunks)
        guard !windows.isEmpty else { return ([], 0, 0) }

        var vecs: [[Float]] = []
        var knownSum = 0
        var totalSum = 0

        for w in windows {
            switch provider {
            case .appleNL:
                if let p = nlProvider {
                    let (v, k, t) = p.embedWithStats(text: w)
                    vecs.append(v)
                    knownSum += k
                    totalSum += t
                }
            case .ollama:
                if let p = ollamaProvider {
                    let (v, k, t) = p.embedWithStats(text: w)
                    vecs.append(v)
                    knownSum += k
                    totalSum += t
                }
            }
        }

        guard !vecs.isEmpty else { return ([], 0, 0) }

        // Determine expected dimension from first vector and normalize to that length.
        let expectedDim = vecs.map { $0.count }.max() ?? 0
        var accum = [Float](repeating: 0, count: expectedDim)
        for v in vecs {
            if v.count == expectedDim {
                for i in 0..<expectedDim { accum[i] += v[i] }
            } else if v.count < expectedDim {
                for i in 0..<v.count { accum[i] += v[i] }
                // leftover positions remain as zeros
            } else { // v.count > expectedDim - truncate
                for i in 0..<expectedDim { accum[i] += v[i] }
            }
        }

        let count = Float(vecs.count)
        if count > 0 {
            for i in 0..<accum.count { accum[i] /= count }
        }

        // L2-normalize final vector
        let final = l2normalize(accum)
        return (final, knownSum, totalSum)
    }
}

// MARK: - NLKit provider (word vectors averaged)
final class NLEmbeddingProvider {
    let dim: Int
    private let emb: NLEmbedding?
    init?() {
        if let e = NLEmbedding.wordEmbedding(for: .english) {
            emb = e
            dim = e.dimension
        } else {
            return nil
        }
    }
    func embed(text: String) -> [Float] { embedWithStats(text: text).0 }

    func embedWithStats(text: String) -> ([Float], Int, Int) {
        guard let emb = emb else { return (Array(repeating: 0, count: dim), 0, 0) }
        let comps = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var v = [Float](repeating: 0, count: dim)
        var count: Float = 0
        var known = 0
        for t in comps {
            if let vec = emb.vector(for: String(t)) {
                for i in 0..<dim { v[i] += Float(vec[i]) }
                known += 1
                count += 1
            }
        }
        if count > 0 { for i in 0..<dim { v[i] /= count } }
        return (v, known, comps.count)
    }
}

// MARK: - Ollama provider (sentence transformers via Ollama API)
final class OllamaEmbeddingProvider {
    typealias MetadataFetcher = (_ model: String, _ baseURL: String) -> Int?

    var dim: Int
    let model: String
    private let baseURL: String
    private static let defaultDim = 384
    private static let metadataQueue = DispatchQueue(label: "com.timescroll.ollama.metadata", attributes: .concurrent)
    private static var dimCache: [String: Int] = [:]
    private static let dimDefaultsKey = "embedding.ollamaDims"
    private static var hasLoadedCache = false

    init(model: String,
         baseURL: String = "http://localhost:11434",
         metadataFetcher: @escaping MetadataFetcher = OllamaEmbeddingProvider.fetchEmbeddingLength) {
        self.model = model
        self.baseURL = baseURL
        if let cached = Self.cachedDim(for: model) {
            self.dim = cached
        } else if let fetched = metadataFetcher(model, baseURL) {
            self.dim = fetched
            Self.storeDim(fetched, for: model)
        } else {
            self.dim = Self.defaultDim
        }
    }

    func embed(text: String) -> [Float] { embedWithStats(text: text).0 }

    func embedWithStats(text: String) -> ([Float], Int, Int) {
        let tokens = text.split(separator: " ").count

        guard let url = URL(string: "\(baseURL)/api/embed") else {
            print("[Ollama] Invalid URL")
            return (Array(repeating: 0, count: dim), 0, 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "input": text
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[Ollama] Failed to serialize JSON")
            return (Array(repeating: 0, count: dim), 0, 0)
        }
        request.httpBody = jsonData

        // Synchronous request (will block)
        var result: [Float] = Array(repeating: 0, count: dim)
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                print("[Ollama] Request error: \(error)")
                return
            }

            guard let data = data else {
                print("[Ollama] No data received")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[Ollama] Failed to parse JSON response")
                return
            }

            // Ollama /api/embed returns: {"model": "...", "embeddings": [[...], ...]}
            // For single input, we get one embedding
            if let embeddings = json["embeddings"] as? [[Double]],
               let embedding = embeddings.first {
                result = embedding.map { Float($0) }
            } else if let embedding = json["embedding"] as? [Double] {
                // Fallback for older API format
                result = embedding.map { Float($0) }
            } else {
                print("[Ollama] No embeddings in response")
            }
        }.resume()

        semaphore.wait()
        // If Ollama returned a different dimension than we expected, update in-memory dim and cache it.
        if !result.isEmpty && result.count != dim {
            dim = result.count
            Self.storeDim(result.count, for: model)
        }
        return (result, tokens, tokens)
    }

    // Check if model is installed
    static func isModelInstalled(_ model: String, baseURL: String = "http://localhost:11434") -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }

        var installed = false
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: url) { data, _, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                installed = models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
            }
        }.resume()

        semaphore.wait()
        return installed
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

    // List available models from Ollama, preferring /api/models then falling back to /api/tags.
    static func listModels(baseURL: String = "http://localhost:11434") -> [String] {
        var out: [String] = []
        let sem = DispatchSemaphore(value: 0)

        func parseModelsJson(_ data: Data) {
            out.append(contentsOf: parseModelsFromData(data))
        }

        if let url = URL(string: "\(baseURL)/api/tags") {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data { parseModelsJson(data) }
                sem.signal()
            }.resume()
            sem.wait()
        }

        let uniq = Array(NSOrderedSet(array: out)) as? [String] ?? out
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

    private static func fetchEmbeddingLength(model: String, baseURL: String) -> Int? {
        guard let url = URL(string: "\(baseURL)/api/show") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["name": model]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let semaphore = DispatchSemaphore(value: 0)
        var length: Int?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard error == nil, let data = data else { return }
            length = parseEmbeddingLength(from: data)
        }.resume()
        semaphore.wait()
        return length
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
