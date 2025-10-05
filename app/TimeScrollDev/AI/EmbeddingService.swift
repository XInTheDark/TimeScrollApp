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
        case ollamaSnowflake = "ollama-snowflake-33m"

        var displayName: String {
            switch self {
            case .appleNL: return "Apple built-in"
            case .ollamaSnowflake: return "Ollama: Snowflake Arctic (33M)"
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

        // Initialize the appropriate provider
        switch selectedProvider {
        case .appleNL:
            nlProvider = NLEmbeddingProvider()
            ollamaProvider = nil
        case .ollamaSnowflake:
            nlProvider = nil
            ollamaProvider = OllamaEmbeddingProvider(model: "snowflake-arctic-embed:33m")
        }
    }

    private(set) var aiEnabled: Bool
    private(set) var threshold: Double
    private(set) var maxCandidates: Int
    private(set) var selectedProvider: Provider

    private let nlProvider: NLEmbeddingProvider?
    private let ollamaProvider: OllamaEmbeddingProvider?

    var dim: Int {
        switch selectedProvider {
        case .appleNL: return nlProvider?.dim ?? 0
        case .ollamaSnowflake: return ollamaProvider?.dim ?? 0
        }
    }

    var providerID: String { selectedProvider.rawValue }

    func embed(_ text: String) -> [Float] {
        return embedWithStats(text).vec
    }

    func embedWithStats(_ text: String) -> (vec: [Float], known: Int, total: Int) {
        let (raw, known, total): ([Float], Int, Int)

        switch selectedProvider {
        case .appleNL:
            guard let p = nlProvider else { return ([], 0, 0) }
            (raw, known, total) = p.embedWithStats(text: text)
        case .ollamaSnowflake:
            guard let p = ollamaProvider else { return ([], 0, 0) }
            (raw, known, total) = p.embedWithStats(text: text)
        }

        let dbg = UserDefaults.standard.bool(forKey: "settings.debugMode")
        if dbg {
            var sum: Float = 0; for x in raw { sum += x*x }
            let norm = sqrtf(sum)
            let head = raw.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
            print("[AI][Embed] provider=\(selectedProvider.rawValue) dim=\(raw.count) known=\(known)/\(total) norm=\(String(format: "%.4f", norm)) head=[\(head)]")
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
    let dim: Int
    let model: String
    private let baseURL: String

    init(model: String, baseURL: String = "http://localhost:11434") {
        self.model = model
        self.baseURL = baseURL
        // snowflake-arctic-embed:33m produces 384-dim vectors
        self.dim = 384
    }

    func embed(text: String) -> [Float] { embedWithStats(text: text).0 }

    func embedWithStats(text: String) -> ([Float], Int, Int) {
        // Snowflake Arctic recommends adding a query prefix for queries
        // For documents, no prefix is needed
        // We'll assume all text is a "query" for now (user search queries)
        // In indexing, we should NOT add the prefix (documents)
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
}
