import Foundation
import NaturalLanguage

// Lightweight embedding service backed ONLY by Apple's NaturalLanguage word embeddings.
// All vectors are L2-normalized Float32 so dot(query, doc) ~ cosine.
final class EmbeddingService {
    static let shared = EmbeddingService()
    private init() {
        // Snapshot settings from UserDefaults; avoid @MainActor SettingsStore per Agents Guide
        let d = UserDefaults.standard
        aiEnabled = (d.object(forKey: "settings.aiEmbeddingsEnabled") != nil) ? d.bool(forKey: "settings.aiEmbeddingsEnabled") : false
        threshold = (d.object(forKey: "settings.aiThreshold") != nil) ? d.double(forKey: "settings.aiThreshold") : 0.5
        maxCandidates = {
            let v = d.integer(forKey: "settings.aiMaxCandidates")
            return v > 0 ? v : 10000
        }()
        provider = NLEmbeddingProvider()
    }

    // Settings snapshot (read-only here)
    private(set) var aiEnabled: Bool
    private(set) var threshold: Double
    private(set) var maxCandidates: Int

    // Provider (NaturalLanguage). Optional: may be unavailable on some systems.
    private let provider: NLEmbeddingProvider?

    var dim: Int { provider?.dim ?? 0 }

    func embed(_ text: String) -> [Float] {
        return embedWithStats(text).vec
    }

    // Returns normalized vector and simple stats useful for debugging.
    func embedWithStats(_ text: String) -> (vec: [Float], known: Int, total: Int) {
        guard let p = provider else { return ([], 0, 0) }
        let (raw, known, total) = p.embedWithStats(text: text)
        // Log if debug enabled
        let dbg = UserDefaults.standard.bool(forKey: "settings.debugMode")
        if dbg {
            var sum: Float = 0; for x in raw { sum += x*x }
            let norm = sqrtf(sum)
            let head = raw.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
            print("[AI][Embed] dim=\(raw.count) known=\(known)/\(total) norm=\(String(format: "%.4f", norm)) head=[\(head)]")
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

// (Legacy provider protocol removed; we exclusively use NaturalLanguage now.)


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

// (Removed hash fallback per NL-only requirement.)
