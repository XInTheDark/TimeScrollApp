import Foundation

final class VectorSearchEngine {
    static let shared = VectorSearchEngine()

    private init() {}

    /// Ranked ids for recent queries, so paging does not re-run the search. Entries expire
    /// quickly; new captures show up on the next fresh query.
    fileprivate struct RankKey: Equatable {
        let identity: VectorSearchIdentity
        let query: [Float]
        let threshold: Float
        let appBundleIds: Set<String>?
        let startMs: Int64?
        let endMs: Int64?
        let captureKinds: Set<CaptureKind>?
        let audioSourceKinds: Set<AudioSourceKind>?
    }
    private static let rankCacheTTL: TimeInterval = 60
    private static let rankCacheCapacity = 4
    private let rankCacheLock = NSLock()
    private var rankCache: [(key: RankKey, ranked: [(id: Int64, score: Float)], createdAt: Date)] = []

    func searchResults(queryVector: [Float],
                       knownTokens: Int,
                       totalTokens: Int,
                       service: EmbeddingService,
                       appBundleIds: [String]?,
                       startMs: Int64?,
                       endMs: Int64?,
                       captureKinds: [CaptureKind]?,
                       audioSourceKinds: [AudioSourceKind]?,
                       limit: Int,
                       offset: Int) -> [SearchResult] {
        guard !queryVector.isEmpty, service.dim > 0 else { return [] }

        let identity = VectorSearchIdentity(provider: service.providerID,
                                            model: service.modelID,
                                            dim: service.dim,
                                            dbPath: DB.shared.dbURL?.path ?? StoragePaths.dbURL().path)
        let threshold = Float(service.effectiveThreshold)
        let key = RankKey(identity: identity,
                          query: queryVector,
                          threshold: threshold,
                          appBundleIds: appBundleIds.map(Set.init),
                          startMs: startMs,
                          endMs: endMs,
                          captureKinds: captureKinds.flatMap { $0.isEmpty ? nil : Set($0) },
                          audioSourceKinds: audioSourceKinds.flatMap { $0.isEmpty ? nil : Set($0) })

        var strategy = "cached"
        let ranked: [(id: Int64, score: Float)]
        if let cached = cachedRanking(for: key) {
            ranked = cached
        } else {
            let stats = (try? DB.shared.embeddingStats(requireDim: service.dim,
                                                       requireProvider: service.providerID,
                                                       requireModel: service.modelID)) ?? EmbeddingStats(count: 0, maxUpdatedAtMs: 0)
            guard stats.count > 0 else { return [] }
            (ranked, strategy) = rank(key: key, stats: stats, requested: limit + offset, maxCandidates: service.maxCandidates)
            storeRanking(ranked, for: key)
            if UserDefaults.standard.bool(forKey: "settings.debugMode") {
                let head = queryVector.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                print("[AI][Query] provider=\(service.providerID) model=\(service.modelID) dim=\(queryVector.count) tokens=\(knownTokens)/\(totalTokens) threshold=\(String(format: "%.2f", threshold)) corpus=\(stats.count) strategy=\(strategy) matches=\(ranked.count) head=[\(head)]")
            }
        }

        let start = max(0, offset)
        let end = min(ranked.count, start + max(0, limit))
        guard start < end else { return [] }
        let page = (try? DB.shared.searchResults(snapshotIds: ranked[start..<end].map(\.id))) ?? []
        return (try? DB.shared.hydrateSearchResultContents(page)) ?? page
    }
}

private extension VectorSearchEngine {
    func rank(key: RankKey, stats: EmbeddingStats, requested: Int, maxCandidates: Int) -> ([(id: Int64, score: Float)], String) {
        let filter = EmbeddingMatrixFilter(startMs: key.startMs,
                                           endMs: key.endMs,
                                           appBundleIds: key.appBundleIds,
                                           captureKinds: key.captureKinds,
                                           audioSourceKinds: key.audioSourceKinds)
        let hasMediaFilters = key.captureKinds != nil || key.audioSourceKinds != nil
        let useANN = !hasMediaFilters && EmbeddingANNIndexBuilder.shouldBuildIndex(for: stats.count)
        let index = useANN ? EmbeddingANNIndexStore.shared.readyIndex(identity: key.identity, stats: stats) : nil
        if useANN, index == nil {
            EmbeddingANNIndexStore.shared.scheduleBuildIfNeeded(identity: key.identity, stats: stats)
        }

        let result = EmbeddingMatrixStore.shared.withMatrix(identity: key.identity, stats: stats) { matrix in
            guard let index, !index.clusters.isEmpty else {
                return (matrix.rank(query: key.query, threshold: key.threshold, filter: filter), "exact")
            }
            return (annRank(matrix: matrix, index: index, key: key, filter: filter,
                            requested: max(1, requested), maxCandidates: maxCandidates), "ann")
        }
        return result ?? ([], "empty")
    }

    /// Probes the nearest clusters, widening until enough matches are found.
    func annRank(matrix: EmbeddingMatrix,
                 index: EmbeddingANNIndex,
                 key: RankKey,
                 filter: EmbeddingMatrixFilter,
                 requested: Int,
                 maxCandidates: Int) -> [(id: Int64, score: Float)] {
        var centroidScores: [(cluster: Int, score: Float)] = []
        centroidScores.reserveCapacity(index.clusters.count)
        for clusterIndex in index.clusters.indices {
            centroidScores.append((clusterIndex, EmbeddingService.dot(key.query, index.clusters[clusterIndex].centroid)))
        }
        centroidScores.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.cluster < rhs.cluster : lhs.score > rhs.score
        }
        let clusterOrder = centroidScores.map(\.cluster)
        let maxFetch = max(maxCandidates, requested * 64)
        var probeCount = min(clusterOrder.count, EmbeddingANNIndexBuilder.initialProbeCount(for: index.clusters.count))
        var ranked: [(id: Int64, score: Float)] = []
        while probeCount > 0 {
            var ids: [Int64] = []
            for clusterIndex in clusterOrder.prefix(probeCount) {
                ids.append(contentsOf: index.clusters[clusterIndex].items.lazy.map(\.snapshotId))
                if ids.count >= maxFetch { break }
            }
            ranked = matrix.rank(query: key.query, threshold: key.threshold, filter: filter, candidateIds: Array(ids.prefix(maxFetch)))
            if ranked.count >= requested || probeCount >= clusterOrder.count { break }
            probeCount = min(clusterOrder.count, probeCount * 2)
        }
        return ranked
    }

    func cachedRanking(for key: RankKey) -> [(id: Int64, score: Float)]? {
        rankCacheLock.lock()
        defer { rankCacheLock.unlock() }
        let now = Date()
        rankCache.removeAll { now.timeIntervalSince($0.createdAt) > Self.rankCacheTTL }
        return rankCache.first { $0.key == key }?.ranked
    }

    func storeRanking(_ ranked: [(id: Int64, score: Float)], for key: RankKey) {
        rankCacheLock.lock()
        defer { rankCacheLock.unlock() }
        rankCache.removeAll { $0.key == key }
        rankCache.insert((key, ranked, Date()), at: 0)
        if rankCache.count > Self.rankCacheCapacity { rankCache.removeLast() }
    }
}
