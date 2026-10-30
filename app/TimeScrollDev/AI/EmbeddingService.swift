import Foundation
import NaturalLanguage
import CoreVideo

// Lightweight embedding service
// Supports multiple embedding providers:
// - Apple NaturalLanguage (word embeddings, averaged)
// - Ollama (snowflake-arctic-embed:33m and other models; multimodal models also embed screenshots)
// All vectors are L2-normalized Float32 so dot(query, doc) ~ cosine.
final class EmbeddingService {
    static let shared = EmbeddingService()

    enum Provider: String, CaseIterable {
        case appleNL = "apple-nl"
        case ollama = "ollama"
        case mobileclip2 = "mobileclip2"

        var displayName: String {
            switch self {
            case .appleNL: return "Apple built-in"
            case .ollama: return "Ollama"
            case .mobileclip2: return "MobileCLIP2"
            }
        }
    }

    enum Usage {
        case query
        case document
    }

    private init() {
        aiEnabled = false
        threshold = 0.5
        maxCandidates = 10000
        selectedProvider = .appleNL
        selectedModel = nil
        reloadFromSettings(eagerProviderSetup: !Thread.isMainThread)
    }

    struct DocumentEmbedding {
        let vector: [Float]
        let providerID: String
        let modelID: String
    }

    private struct StateSnapshot {
        let provider: Provider
        let model: String?
        let nlProvider: NLEmbeddingProvider?
        let ollamaProvider: OllamaEmbeddingProvider?
        let mobileclipProvider: MobileCLIP2EmbeddingProvider?
    }

    private let stateLock = NSRecursiveLock()

    private(set) var aiEnabled: Bool
    private(set) var threshold: Double
    private(set) var maxCandidates: Int
    private(set) var selectedProvider: Provider
    private(set) var selectedModel: String?

        private var nlProvider: NLEmbeddingProvider?
        private var ollamaProvider: OllamaEmbeddingProvider?
        private var mobileclipProvider: MobileCLIP2EmbeddingProvider?

    var dim: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch selectedProvider {
        case .appleNL: return nlProvider?.dim ?? 0
        case .ollama: return ollamaProvider?.dim ?? 0
        case .mobileclip2: return mobileclipProvider?.dim ?? 0
        }
    }

    // Reload selection from UserDefaults — used after settings change
    func reloadFromSettings(eagerProviderSetup: Bool = !Thread.isMainThread, onlyIfSelectionChanged: Bool = false) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let previousProvider = selectedProvider
        let previousModel = selectedModel
        let d = UserDefaults.standard
        aiEnabled = (d.object(forKey: "settings.aiEmbeddingsEnabled") != nil) ? d.bool(forKey: "settings.aiEmbeddingsEnabled") : false
        threshold = (d.object(forKey: "settings.aiThreshold") != nil) ? d.double(forKey: "settings.aiThreshold") : 0.5
        maxCandidates = {
            let v = d.integer(forKey: "settings.aiMaxCandidates")
            return v > 0 ? v : 10000
        }()
        if let raw = d.string(forKey: "settings.embeddingProvider"), let p = Provider(rawValue: raw) {
            selectedProvider = p
        } else {
            selectedProvider = .appleNL
        }
        selectedModel = Self.selectedModel(from: d, provider: selectedProvider)

        if onlyIfSelectionChanged, previousProvider == selectedProvider, previousModel == selectedModel {
            // Retry unavailable providers, including those created lazily on the main thread.
            if dim > 0 { return }
        }

        switch selectedProvider {
        case .appleNL:
            nlProvider = NLEmbeddingProvider()
            ollamaProvider = nil
            mobileclipProvider = nil
        case .ollama:
            nlProvider = nil
            let model = selectedModel ?? Self.defaultModel(for: .ollama)
            ollamaProvider = OllamaEmbeddingProvider(model: model, eagerlyResolveDimension: eagerProviderSetup)
            mobileclipProvider = nil
        case .mobileclip2:
            nlProvider = nil
            ollamaProvider = nil
            let model = selectedModel ?? Self.defaultModel(for: .mobileclip2)
            mobileclipProvider = MobileCLIP2EmbeddingProvider(modelName: model, eagerlyLoadRuntime: eagerProviderSetup)
        }
    }

    var providerID: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedProvider.rawValue
    }
    var modelID: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Self.resolvedModelID(provider: selectedProvider, selectedModel: selectedModel)
    }

    private static func resolvedModelID(provider: Provider, selectedModel: String?) -> String {
        switch provider {
        case .appleNL:
            return "apple-nl-en"
        case .ollama:
            return selectedModel ?? defaultModel(for: .ollama)
        case .mobileclip2:
            return selectedModel ?? defaultModel(for: .mobileclip2)
        }
    }

    private func stateSnapshot() -> StateSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return StateSnapshot(provider: selectedProvider,
                             model: selectedModel,
                             nlProvider: nlProvider,
                             ollamaProvider: ollamaProvider,
                             mobileclipProvider: mobileclipProvider)
    }

    var supportsImageDocuments: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch selectedProvider {
        case .appleNL: return false
        case .ollama: return ollamaProvider?.supportsImageInput ?? false
        case .mobileclip2: return true
        }
    }

    /// Re-checks whether the selected model embeds images (blocking); call off the main thread.
    func refreshImageSupport() {
        stateSnapshot().ollamaProvider?.refreshImageSupport()
    }

    /// Long edge for the private frame copy kept for image embedding. MobileCLIP center-crops and
    /// resizes to ~256 px anyway; Ollama vision encoders benefit from more detail on screen text.
    var imageDocumentMaxEdge: CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedProvider == .ollama ? 896 : 512
    }

    var effectiveThreshold: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        if selectedProvider == .mobileclip2, abs(threshold - 0.30) < 0.0001 {
            return 0.15
        }
        return threshold
    }

    func embed(_ text: String, usage: Usage = .document) -> [Float] {
        return embedWithStats(text, usage: usage).vec
    }

    func embedWithStats(_ text: String, usage: Usage = .document) -> (vec: [Float], known: Int, total: Int) {
        embedWithStats(text, usage: usage, state: stateSnapshot())
    }

    private func embedWithStats(_ text: String,
                                usage: Usage,
                                state: StateSnapshot) -> (vec: [Float], known: Int, total: Int) {
        // If text is very long, break into multiple chunks and average embeddings.
        let (raw, known, total): ([Float], Int, Int)

        // Use provider-agnostic long-text embedding util when text exceeds a threshold.
        let maxInput = 2_000
        if state.provider != .mobileclip2, text.count > maxInput {
            (raw, known, total) = Self.embedLongTextWithStats(text: text, maxInput: maxInput, maxChunks: 10, overlapPct: 0.10, provider: state.provider, nlProvider: state.nlProvider, ollamaProvider: state.ollamaProvider, usage: usage)
        } else {
            switch state.provider {
            case .appleNL:
                guard let p = state.nlProvider else { return ([], 0, 0) }
                (raw, known, total) = p.embedWithStats(text: text)
            case .ollama:
                guard let p = state.ollamaProvider else { return ([], 0, 0) }
                (raw, known, total) = p.embedWithStats(text: text, usage: usage)
            case .mobileclip2:
                guard let p = state.mobileclipProvider else { return ([], 0, 0) }
                (raw, known, total) = p.embedTextWithStats(text: text)
            }
        }

        let dbg = UserDefaults.standard.bool(forKey: "settings.debugMode")
        if dbg {
            var sum: Float = 0; for x in raw { sum += x*x }
            let norm = sqrtf(sum)
            let head = raw.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
            let model = state.model ?? state.provider.rawValue
            print("[AI][Embed] provider=\(state.provider.rawValue) model=\(model) dim=\(raw.count) known=\(known)/\(total) norm=\(String(format: "%.4f", norm)) head=[\(head)]")
        }
        return (Self.l2normalize(raw), known, total)
    }

    func embedDocument(pixelBuffer: CVPixelBuffer?, extractedText: String?) -> [Float] {
        embedDocument(pixelBuffer: pixelBuffer, extractedText: extractedText, state: stateSnapshot())
    }

    private func embedDocument(pixelBuffer: CVPixelBuffer?, extractedText: String?, state: StateSnapshot) -> [Float] {
        switch state.provider {
        case .appleNL:
            guard let extractedText, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return embedWithStats(extractedText, usage: .document, state: state).vec
        case .ollama:
            if let provider = state.ollamaProvider, let pixelBuffer, provider.supportsImageInput {
                let includeText = UserDefaults.standard.bool(forKey: "settings.multimodalIncludeExtractedText")
                let vector = provider.embedImageDocument(pixelBuffer: pixelBuffer,
                                                         extractedText: includeText ? extractedText : nil)
                if !vector.isEmpty { return Self.l2normalize(vector) }
            }
            guard let extractedText, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return embedWithStats(extractedText, usage: .document, state: state).vec
        case .mobileclip2:
            guard let provider = state.mobileclipProvider, let pixelBuffer else { return [] }
            let includeText = UserDefaults.standard.bool(forKey: "settings.multimodalIncludeExtractedText")
            return provider.embedDocument(pixelBuffer: pixelBuffer, extractedText: extractedText, includeText: includeText)
        }
    }

    func embedDocumentWithIdentity(pixelBuffer: CVPixelBuffer?, extractedText: String?) -> DocumentEmbedding? {
        let state = stateSnapshot()
        let vector = embedDocument(pixelBuffer: pixelBuffer, extractedText: extractedText, state: state)
        guard !vector.isEmpty else { return nil }
        return DocumentEmbedding(vector: vector,
                                 providerID: state.provider.rawValue,
                                 modelID: Self.resolvedModelID(provider: state.provider, selectedModel: state.model))
    }

    private static func selectedModel(from defaults: UserDefaults, provider: Provider) -> String? {
        switch provider {
        case .appleNL:
            return nil
        case .ollama, .mobileclip2:
            return defaults.string(forKey: "settings.embeddingModel") ?? defaultModel(for: provider)
        }
    }

    private static func defaultModel(for provider: Provider) -> String {
        switch provider {
        case .appleNL:
            return "apple-nl-en"
        case .ollama:
            return "snowflake-arctic-embed:33m"
        case .mobileclip2:
            return MobileCLIPModelCatalog.Model.s0.rawValue
        }
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
                                       ollamaProvider: OllamaEmbeddingProvider?,
                                       usage: Usage = .document) -> ([Float], Int, Int) {
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
                    let (v, k, t) = p.embedWithStats(text: w, usage: usage)
                    vecs.append(v)
                    knownSum += k
                    totalSum += t
                }
            case .mobileclip2:
                break
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
