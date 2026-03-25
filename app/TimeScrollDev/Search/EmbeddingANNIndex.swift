import Foundation

struct VectorSearchIdentity: Hashable, Codable {
    let provider: String
    let model: String
    let dim: Int
    let dbPath: String

    var cacheKey: String {
        "\(provider)|\(model)|\(dim)|\(dbPath)"
    }
}

struct EmbeddingANNIndexMetadata: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let provider: String
    let model: String
    let dim: Int
    let dbPath: String
    var embeddingCount: Int
    var maxUpdatedAtMs: Int64
    var clusterCount: Int
    var builtAtMs: Int64

    func matches(identity: VectorSearchIdentity, stats: EmbeddingStats) -> Bool {
        version == Self.currentVersion
            && provider == identity.provider
            && model == identity.model
            && dim == identity.dim
            && dbPath == identity.dbPath
            && embeddingCount == stats.count
            && maxUpdatedAtMs == stats.maxUpdatedAtMs
    }
}

struct EmbeddingANNPostingEntry: Codable, Hashable {
    let snapshotId: Int64
    let startedAtMs: Int64
    let appBundleId: String?
}

struct EmbeddingANNCluster: Codable, Hashable {
    var centroid: [Float]
    var items: [EmbeddingANNPostingEntry]
}

struct EmbeddingANNIndex: Codable {
    var metadata: EmbeddingANNIndexMetadata
    var clusters: [EmbeddingANNCluster]
}

enum EmbeddingANNIndexBuilder {
    static let minimumCorpusSize = 12_000

    static func shouldBuildIndex(for embeddingCount: Int) -> Bool {
        embeddingCount >= minimumCorpusSize
    }

    static func initialProbeCount(for clusterCount: Int) -> Int {
        guard clusterCount > 0 else { return 0 }
        let proposed = Int(Double(clusterCount).squareRoot().rounded(.up) / 2.0)
        return min(clusterCount, max(2, proposed))
    }

    static func build(identity: VectorSearchIdentity,
                      stats: EmbeddingStats,
                      entries: [EmbeddingIndexEntry]) -> EmbeddingANNIndex? {
        guard !entries.isEmpty else { return nil }

        let vectorDim = entries[0].vector.count
        guard vectorDim > 0 else { return nil }

        let clusterCount = min(entries.count, preferredClusterCount(for: entries.count))
        guard clusterCount > 0 else { return nil }

        let sample = sampledEntries(from: entries, targetCount: preferredSampleCount(for: entries.count, clusterCount: clusterCount))
        var centroids = initialCentroids(from: sample, count: clusterCount)
        guard !centroids.isEmpty else { return nil }

        let iterations = entries.count >= 50_000 ? 3 : 4
        for iteration in 0..<iterations {
            centroids = refineCentroids(sample: sample, centroids: centroids, iteration: iteration)
        }

        var postings = Array(repeating: [EmbeddingANNPostingEntry](), count: centroids.count)
        var sums = Array(repeating: Array(repeating: Float.zero, count: vectorDim), count: centroids.count)
        var counts = Array(repeating: 0, count: centroids.count)

        for entry in entries {
            let clusterIndex = nearestCentroidIndex(for: entry.vector, centroids: centroids)
            postings[clusterIndex].append(
                EmbeddingANNPostingEntry(snapshotId: entry.snapshotId,
                                         startedAtMs: entry.startedAtMs,
                                         appBundleId: entry.appBundleId)
            )
            counts[clusterIndex] += 1
            add(entry.vector, to: &sums[clusterIndex])
        }

        var clusters: [EmbeddingANNCluster] = []
        clusters.reserveCapacity(centroids.count)
        for index in centroids.indices {
            guard !postings[index].isEmpty else { continue }
            postings[index].sort { lhs, rhs in
                if lhs.startedAtMs == rhs.startedAtMs {
                    return lhs.snapshotId > rhs.snapshotId
                }
                return lhs.startedAtMs > rhs.startedAtMs
            }
            let centroid: [Float]
            if counts[index] > 0 {
                centroid = normalizedAverage(sum: sums[index], count: counts[index])
            } else {
                centroid = centroids[index]
            }
            clusters.append(EmbeddingANNCluster(centroid: centroid, items: postings[index]))
        }

        guard !clusters.isEmpty else { return nil }

        let metadata = EmbeddingANNIndexMetadata(
            version: EmbeddingANNIndexMetadata.currentVersion,
            provider: identity.provider,
            model: identity.model,
            dim: identity.dim,
            dbPath: identity.dbPath,
            embeddingCount: stats.count,
            maxUpdatedAtMs: stats.maxUpdatedAtMs,
            clusterCount: clusters.count,
            builtAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        return EmbeddingANNIndex(metadata: metadata, clusters: clusters)
    }

    private static func preferredClusterCount(for count: Int) -> Int {
        let scaled = Int(Double(count).squareRoot() / 3.0)
        return min(64, max(16, scaled))
    }

    private static func preferredSampleCount(for count: Int, clusterCount: Int) -> Int {
        min(count, max(clusterCount * 24, 1_024))
    }

    private static func sampledEntries(from entries: [EmbeddingIndexEntry], targetCount: Int) -> [EmbeddingIndexEntry] {
        guard targetCount < entries.count else { return entries }
        var chosen: [EmbeddingIndexEntry] = []
        chosen.reserveCapacity(targetCount)
        var seen = Set<Int>()
        var state: UInt64 = 0x9E3779B97F4A7C15
        while chosen.count < targetCount {
            state = state &* 2862933555777941757 &+ 3037000493
            let index = Int(state % UInt64(entries.count))
            if seen.insert(index).inserted {
                chosen.append(entries[index])
            }
        }
        return chosen
    }

    private static func initialCentroids(from sample: [EmbeddingIndexEntry], count: Int) -> [[Float]] {
        guard !sample.isEmpty, count > 0 else { return [] }
        var centroids: [[Float]] = []
        centroids.reserveCapacity(count)
        var seen = Set<Int>()
        var state: UInt64 = 0xD1B54A32D192ED03
        while centroids.count < min(count, sample.count) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let index = Int(state % UInt64(sample.count))
            if seen.insert(index).inserted {
                centroids.append(sample[index].vector)
            }
        }
        return centroids
    }

    private static func refineCentroids(sample: [EmbeddingIndexEntry], centroids: [[Float]], iteration: Int) -> [[Float]] {
        guard !sample.isEmpty, !centroids.isEmpty else { return centroids }
        let vectorDim = centroids[0].count
        var sums = Array(repeating: Array(repeating: Float.zero, count: vectorDim), count: centroids.count)
        var counts = Array(repeating: 0, count: centroids.count)
        for entry in sample {
            let clusterIndex = nearestCentroidIndex(for: entry.vector, centroids: centroids)
            counts[clusterIndex] += 1
            add(entry.vector, to: &sums[clusterIndex])
        }

        var updated = centroids
        for index in updated.indices {
            if counts[index] > 0 {
                updated[index] = normalizedAverage(sum: sums[index], count: counts[index])
            } else {
                let fallbackIndex = (iteration + index) % sample.count
                updated[index] = sample[fallbackIndex].vector
            }
        }
        return updated
    }

    private static func nearestCentroidIndex(for vector: [Float], centroids: [[Float]]) -> Int {
        precondition(!centroids.isEmpty)
        var bestIndex = 0
        var bestScore = EmbeddingService.dot(vector, centroids[0])
        if centroids.count == 1 { return 0 }
        for index in 1..<centroids.count {
            let score = EmbeddingService.dot(vector, centroids[index])
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func add(_ vector: [Float], to destination: inout [Float]) {
        guard destination.count == vector.count else { return }
        for index in vector.indices {
            destination[index] += vector[index]
        }
    }

    private static func normalizedAverage(sum: [Float], count: Int) -> [Float] {
        guard count > 0 else { return sum }
        let divisor = Float(count)
        var averaged = sum
        for index in averaged.indices {
            averaged[index] /= divisor
        }
        return EmbeddingService.l2normalize(averaged)
    }
}
