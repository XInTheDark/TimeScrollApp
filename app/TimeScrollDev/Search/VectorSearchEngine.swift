import Foundation

final class VectorSearchEngine {
    static let shared = VectorSearchEngine()

    private init() {}

    func searchResults(queryVector: [Float],
                       knownTokens: Int,
                       totalTokens: Int,
                       service: EmbeddingService,
                       appBundleIds: [String]?,
                       startMs: Int64?,
                       endMs: Int64?,
                       limit: Int,
                       offset: Int) -> [SearchResult] {
        guard !queryVector.isEmpty, service.dim > 0 else { return [] }

        let identity = VectorSearchIdentity(provider: service.providerID,
                                            model: service.modelID,
                                            dim: service.dim,
                                            dbPath: DB.shared.dbURL?.path ?? StoragePaths.dbURL().path)
        let stats = (try? DB.shared.embeddingStats(requireDim: service.dim,
                                                   requireProvider: service.providerID,
                                                   requireModel: service.modelID)) ?? EmbeddingStats(count: 0, maxUpdatedAtMs: 0)
        guard stats.count > 0 else { return [] }

        let threshold = Float(service.effectiveThreshold)
        let debugEnabled = UserDefaults.standard.bool(forKey: "settings.debugMode")
        let strategy: String
        let rawResults: [SearchResult]

        if EmbeddingANNIndexBuilder.shouldBuildIndex(for: stats.count),
           let index = EmbeddingANNIndexStore.shared.readyIndex(identity: identity, stats: stats) {
            strategy = "ann"
            rawResults = annSearch(queryVector: queryVector,
                                   threshold: threshold,
                                   service: service,
                                   identity: identity,
                                   index: index,
                                   appBundleIds: appBundleIds,
                                   startMs: startMs,
                                   endMs: endMs,
                                   limit: limit,
                                   offset: offset)
        } else {
            let fullScan = !EmbeddingANNIndexBuilder.shouldBuildIndex(for: stats.count)
            strategy = fullScan ? "exact-full" : "exact-fallback"
            if !fullScan {
                EmbeddingANNIndexStore.shared.scheduleBuildIfNeeded(identity: identity, stats: stats)
            }
            rawResults = exactSearch(queryVector: queryVector,
                                     threshold: threshold,
                                     service: service,
                                     stats: stats,
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     limit: limit,
                                     offset: offset,
                                     fullScan: fullScan)
        }

        if debugEnabled {
            let head = queryVector.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
            print("[AI][Query] provider=\(service.providerID) model=\(service.modelID) dim=\(queryVector.count) tokens=\(knownTokens)/\(totalTokens) threshold=\(String(format: "%.2f", threshold)) corpus=\(stats.count) strategy=\(strategy) head=[\(head)]")
        }

        return rawResults
    }
}

private extension VectorSearchEngine {
    func exactSearch(queryVector: [Float],
                     threshold: Float,
                     service: EmbeddingService,
                     stats: EmbeddingStats,
                     appBundleIds: [String]?,
                     startMs: Int64?,
                     endMs: Int64?,
                     limit: Int,
                     offset: Int,
                     fullScan: Bool) -> [SearchResult] {
        let fetchLimit = fullScan
            ? max(limit + offset, stats.count)
            : max(limit + offset, service.maxCandidates)
        let candidates = (try? DB.shared.embeddingCandidates(appBundleIds: appBundleIds,
                                                             startMs: startMs,
                                                             endMs: endMs,
                                                             limit: fetchLimit,
                                                             offset: 0,
                                                             requireDim: service.dim,
                                                             requireProvider: service.providerID,
                                                             requireModel: service.modelID)) ?? []
        let ranked = rankCandidates(candidates, queryVector: queryVector, threshold: threshold)
        return hydratePage(from: ranked, limit: limit, offset: offset)
    }

    func annSearch(queryVector: [Float],
                   threshold: Float,
                   service: EmbeddingService,
                   identity: VectorSearchIdentity,
                   index: EmbeddingANNIndex,
                   appBundleIds: [String]?,
                   startMs: Int64?,
                   endMs: Int64?,
                   limit: Int,
                   offset: Int) -> [SearchResult] {
        guard !index.clusters.isEmpty else { return [] }

        let requestedResults = max(1, limit + offset)
        let appFilter = appBundleIds.map(Set.init)
        let maxFetch = max(service.maxCandidates, requestedResults * 64)
        let clusterOrder = orderedClusters(for: queryVector, in: index)
        var probeCount = min(clusterOrder.count, EmbeddingANNIndexBuilder.initialProbeCount(for: index.clusters.count))
        var bestRanked: [SearchResult] = []

        while probeCount > 0 {
            let candidateIds = collectCandidateIDs(clusterOrder: clusterOrder,
                                                   clusterLimit: probeCount,
                                                   index: index,
                                                   appFilter: appFilter,
                                                   startMs: startMs,
                                                   endMs: endMs,
                                                   maxFetch: maxFetch)
            if candidateIds.isEmpty {
                if probeCount >= clusterOrder.count { break }
                probeCount = min(clusterOrder.count, probeCount * 2)
                continue
            }

            let candidates = (try? DB.shared.embeddingCandidates(snapshotIds: candidateIds,
                                                                 requireDim: identity.dim,
                                                                 requireProvider: identity.provider,
                                                                 requireModel: identity.model)) ?? []
            let ranked = rankCandidates(candidates, queryVector: queryVector, threshold: threshold)
            bestRanked = ranked
            if ranked.count >= requestedResults || probeCount >= clusterOrder.count {
                break
            }
            probeCount = min(clusterOrder.count, max(probeCount + 1, probeCount * 2))
        }

        return hydratePage(from: bestRanked, limit: limit, offset: offset)
    }

    func orderedClusters(for queryVector: [Float], in index: EmbeddingANNIndex) -> [(clusterIndex: Int, score: Float)] {
        index.clusters.indices
            .map { clusterIndex in
                (clusterIndex, EmbeddingService.dot(queryVector, index.clusters[clusterIndex].centroid))
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.clusterIndex < rhs.clusterIndex
                }
                return lhs.score > rhs.score
            }
    }

    func collectCandidateIDs(clusterOrder: [(clusterIndex: Int, score: Float)],
                             clusterLimit: Int,
                             index: EmbeddingANNIndex,
                             appFilter: Set<String>?,
                             startMs: Int64?,
                             endMs: Int64?,
                             maxFetch: Int) -> [Int64] {
        var ids: [Int64] = []
        ids.reserveCapacity(min(maxFetch, 4_096))
        var seen = Set<Int64>()

        for ordered in clusterOrder.prefix(clusterLimit) {
            let cluster = index.clusters[ordered.clusterIndex]
            for item in cluster.items {
                if let startMs, item.startedAtMs < startMs { continue }
                if let endMs, item.startedAtMs > endMs { continue }
                if let appFilter {
                    guard let appBundleId = item.appBundleId, appFilter.contains(appBundleId) else { continue }
                }
                if seen.insert(item.snapshotId).inserted {
                    ids.append(item.snapshotId)
                    if ids.count >= maxFetch {
                        return ids
                    }
                }
            }
        }

        return ids
    }

    func rankCandidates(_ candidates: [EmbeddingCandidate], queryVector: [Float], threshold: Float) -> [SearchResult] {
        var scored: [(SearchResult, Float)] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates {
            let score = EmbeddingService.dot(queryVector, candidate.vector)
            if score >= threshold {
                scored.append((candidate.result, score))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.startedAtMs > rhs.0.startedAtMs
            }
            return lhs.1 > rhs.1
        }
        return scored.map(\.0)
    }

    func hydratePage(from ranked: [SearchResult], limit: Int, offset: Int) -> [SearchResult] {
        let start = max(0, offset)
        let end = min(ranked.count, start + max(0, limit))
        guard start < end else { return [] }
        let page = Array(ranked[start..<end])
        return (try? DB.shared.hydrateSearchResultContents(page)) ?? page
    }
}
