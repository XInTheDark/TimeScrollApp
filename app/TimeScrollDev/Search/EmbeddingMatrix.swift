import Accelerate
import Foundation

/// One embedding row as loaded from the database.
struct EmbeddingMatrixRow {
    let snapshotId: Int64
    let startedAtMs: Int64
    let appBundleId: String?
    let captureKind: CaptureKind
    let audioSourceKind: AudioSourceKind?
    let vector: [Float]
    let updatedAtMs: Int64
}

/// Filters applied while scoring.
struct EmbeddingMatrixFilter {
    let startMs: Int64?
    let endMs: Int64?
    let appBundleIds: Set<String>?
    let captureKinds: Set<CaptureKind>?
    let audioSourceKinds: Set<AudioSourceKind>?
}

/// All vectors of one embedding identity in a contiguous Int8 matrix (per-row scale), scored
/// block-wise with vDSP. Vectors are L2-normalized, so symmetric Int8 quantization changes
/// cosine scores by well under 1% while using a quarter of the Float32 memory.
final class EmbeddingMatrix {
    let dim: Int
    private(set) var stats: EmbeddingStats
    private var ids: [Int64] = []
    private var startedAtMs: [Int64] = []
    private var appBundleIds: [String?] = []
    private var captureKinds: [CaptureKind] = []
    private var audioSourceKinds: [AudioSourceKind?] = []
    private var scales: [Float] = []
    private var values: [Int8] = []
    private var rowById: [Int64: Int] = [:]

    private static let blockRows = 2048

    init(dim: Int) {
        self.dim = dim
        self.stats = EmbeddingStats(count: 0, maxUpdatedAtMs: 0)
    }

    var rowCount: Int { ids.count }

    func upsert(_ row: EmbeddingMatrixRow) {
        guard row.vector.count >= dim else { return }
        let (quantized, scale) = Self.quantize(row.vector, dim: dim)
        if let index = rowById[row.snapshotId] {
            values.replaceSubrange(index * dim ..< (index + 1) * dim, with: quantized)
            scales[index] = scale
            startedAtMs[index] = row.startedAtMs
            appBundleIds[index] = row.appBundleId
            captureKinds[index] = row.captureKind
            audioSourceKinds[index] = row.audioSourceKind
        } else {
            rowById[row.snapshotId] = ids.count
            ids.append(row.snapshotId)
            startedAtMs.append(row.startedAtMs)
            appBundleIds.append(row.appBundleId)
            captureKinds.append(row.captureKind)
            audioSourceKinds.append(row.audioSourceKind)
            scales.append(scale)
            values.append(contentsOf: quantized)
        }
        stats = EmbeddingStats(count: ids.count, maxUpdatedAtMs: max(stats.maxUpdatedAtMs, row.updatedAtMs))
    }

    /// Scores rows (all, or only `candidateIds`) and returns matches at or above `threshold`,
    /// best first; ties go to the newer snapshot.
    func rank(query: [Float], threshold: Float, filter: EmbeddingMatrixFilter, candidateIds: [Int64]? = nil) -> [(id: Int64, score: Float)] {
        guard query.count >= dim, !ids.isEmpty else { return [] }
        var scored: [(id: Int64, score: Float, startedAtMs: Int64)] = []
        if let candidateIds {
            let rows = candidateIds.compactMap { rowById[$0] }.filter { passes(row: $0, filter: filter) }
            var scratch = [Float](repeating: 0, count: dim)
            for row in rows {
                let score = score(row: row, query: query, scratch: &scratch)
                if score >= threshold { scored.append((ids[row], score, startedAtMs[row])) }
            }
        } else {
            scanAll(query: query) { row, score in
                if score >= threshold, passes(row: row, filter: filter) {
                    scored.append((ids[row], score, startedAtMs[row]))
                }
            }
        }
        scored.sort { $0.score == $1.score ? $0.startedAtMs > $1.startedAtMs : $0.score > $1.score }
        return scored.map { ($0.id, $0.score) }
    }

    private func passes(row: Int, filter: EmbeddingMatrixFilter) -> Bool {
        if let startMs = filter.startMs, startedAtMs[row] < startMs { return false }
        if let endMs = filter.endMs, startedAtMs[row] > endMs { return false }
        if let apps = filter.appBundleIds {
            guard let app = appBundleIds[row], apps.contains(app) else { return false }
        }
        if let kinds = filter.captureKinds, !kinds.contains(captureKinds[row]) { return false }
        if let sources = filter.audioSourceKinds {
            guard let source = audioSourceKinds[row], sources.contains(source) else { return false }
        }
        return true
    }

    private func scanAll(query: [Float], visit: (Int, Float) -> Void) {
        let blockRows = Self.blockRows
        var floats = [Float](repeating: 0, count: blockRows * dim)
        var scores = [Float](repeating: 0, count: blockRows)
        var start = 0
        while start < ids.count {
            let rows = min(blockRows, ids.count - start)
            let n = rows * dim
            values.withUnsafeBufferPointer { src in
                floats.withUnsafeMutableBufferPointer { dst in
                    vDSP_vflt8(src.baseAddress! + start * dim, 1, dst.baseAddress!, 1, vDSP_Length(n))
                }
            }
            // (rows x dim) * (dim x 1) -> rows
            vDSP_mmul(floats, 1, query, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(dim))
            for offset in 0..<rows {
                visit(start + offset, scores[offset] * scales[start + offset])
            }
            start += rows
        }
    }

    private func score(row: Int, query: [Float], scratch: inout [Float]) -> Float {
        values.withUnsafeBufferPointer { src in
            scratch.withUnsafeMutableBufferPointer { dst in
                vDSP_vflt8(src.baseAddress! + row * dim, 1, dst.baseAddress!, 1, vDSP_Length(dim))
            }
        }
        var dot: Float = 0
        vDSP_dotpr(scratch, 1, query, 1, &dot, vDSP_Length(dim))
        return dot * scales[row]
    }

    private static func quantize(_ vector: [Float], dim: Int) -> ([Int8], Float) {
        var maxAbs: Float = 0
        vDSP_maxmgv(vector, 1, &maxAbs, vDSP_Length(dim))
        guard maxAbs > 0 else { return ([Int8](repeating: 0, count: dim), 0) }
        let scale = maxAbs / 127
        let quantized = vector.prefix(dim).map { Int8(max(-127, min(127, ($0 / scale).rounded()))) }
        return (quantized, scale)
    }
}
