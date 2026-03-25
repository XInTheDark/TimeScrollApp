import Foundation
import CryptoKit

final class EmbeddingANNIndexStore {
    static let shared = EmbeddingANNIndexStore()

    private struct PendingUpsert {
        let snapshotId: Int64
        let startedAtMs: Int64
        let appBundleId: String?
        let vector: [Float]
        let updatedAtMs: Int64
    }

    private let queue = DispatchQueue(label: "TimeScroll.Search.EmbeddingANNIndexStore", qos: .utility)
    private var cache: [VectorSearchIdentity: EmbeddingANNIndex] = [:]
    private var buildsInFlight: Set<VectorSearchIdentity> = []
    private var buildGenerations: [VectorSearchIdentity: Int] = [:]
    private var pendingSaves: [VectorSearchIdentity: DispatchWorkItem] = [:]
    private var pendingUpserts: [VectorSearchIdentity: [PendingUpsert]] = [:]

    private init() {}

    func readyIndex(identity: VectorSearchIdentity, stats: EmbeddingStats) -> EmbeddingANNIndex? {
        queue.sync {
            guard EmbeddingANNIndexBuilder.shouldBuildIndex(for: stats.count) else {
                cache.removeValue(forKey: identity)
                return nil
            }

            if let cached = cache[identity], cached.metadata.matches(identity: identity, stats: stats) {
                return cached
            }
            cache.removeValue(forKey: identity)

            guard let loaded = loadIndexFromDisk(identity: identity, stats: stats) else {
                return nil
            }
            cache[identity] = loaded
            return loaded
        }
    }

    func scheduleBuildIfNeeded(identity: VectorSearchIdentity, stats: EmbeddingStats) {
        queue.async {
            guard EmbeddingANNIndexBuilder.shouldBuildIndex(for: stats.count) else { return }
            if let cached = self.cache[identity], cached.metadata.matches(identity: identity, stats: stats) {
                return
            }
            guard !self.buildsInFlight.contains(identity) else { return }
            self.buildsInFlight.insert(identity)
            let generation = (self.buildGenerations[identity] ?? 0) + 1
            self.buildGenerations[identity] = generation

            DispatchQueue.global(qos: .utility).async {
                let built = self.buildIndex(identity: identity, stats: stats)
                self.queue.async {
                    self.buildsInFlight.remove(identity)
                    guard self.buildGenerations[identity] == generation else { return }
                    guard var built else { return }
                    if let upserts = self.pendingUpserts.removeValue(forKey: identity) {
                        for upsert in upserts {
                            built = self.applying(upsert, to: built)
                        }
                    }
                    self.cache[identity] = built
                    self.saveIndexSoon(built, identity: identity, delay: 0)
                }
            }
        }
    }

    func recordUpsert(identity: VectorSearchIdentity,
                      snapshotId: Int64,
                      startedAtMs: Int64,
                      appBundleId: String?,
                      vector: [Float],
                      updatedAtMs: Int64) {
        queue.async {
            let upsert = PendingUpsert(snapshotId: snapshotId,
                                       startedAtMs: startedAtMs,
                                       appBundleId: appBundleId,
                                       vector: vector,
                                       updatedAtMs: updatedAtMs)
            if self.buildsInFlight.contains(identity) {
                self.pendingUpserts[identity, default: []].append(upsert)
                return
            }
            guard var index = self.cache[identity],
                  index.metadata.version == EmbeddingANNIndexMetadata.currentVersion,
                  index.metadata.provider == identity.provider,
                  index.metadata.model == identity.model,
                  index.metadata.dim == identity.dim,
                  index.metadata.dbPath == identity.dbPath,
                  !index.clusters.isEmpty else { return }
            index = self.applying(upsert, to: index)
            self.cache[identity] = index
            self.saveIndexSoon(index, identity: identity, delay: 3.0)
        }
    }

    func invalidate(identity: VectorSearchIdentity) {
        queue.async {
            self.buildGenerations[identity] = (self.buildGenerations[identity] ?? 0) + 1
            self.pendingSaves.removeValue(forKey: identity)?.cancel()
            self.cache.removeValue(forKey: identity)
            self.buildsInFlight.remove(identity)
            self.pendingUpserts.removeValue(forKey: identity)
            self.removeIndexFile(for: identity)
        }
    }

    func clearMemory() {
        queue.async {
            self.pendingSaves.values.forEach { $0.cancel() }
            self.pendingSaves.removeAll()
            self.pendingUpserts.removeAll()
            self.cache.removeAll()
            self.buildsInFlight.removeAll()
            self.buildGenerations.removeAll()
        }
    }
}

private extension EmbeddingANNIndexStore {
    func buildIndex(identity: VectorSearchIdentity, stats: EmbeddingStats) -> EmbeddingANNIndex? {
        let entries = (try? DB.shared.embeddingIndexEntries(requireDim: identity.dim,
                                                            requireProvider: identity.provider,
                                                            requireModel: identity.model)) ?? []
        guard !entries.isEmpty else { return nil }
        return EmbeddingANNIndexBuilder.build(identity: identity, stats: stats, entries: entries)
    }

    func nearestCentroidIndex(for vector: [Float], index: EmbeddingANNIndex) -> Int {
        guard !index.clusters.isEmpty else { return 0 }
        var bestIndex = 0
        var bestScore = EmbeddingService.dot(vector, index.clusters[0].centroid)
        if index.clusters.count == 1 { return 0 }
        for clusterIndex in 1..<index.clusters.count {
            let score = EmbeddingService.dot(vector, index.clusters[clusterIndex].centroid)
            if score > bestScore {
                bestScore = score
                bestIndex = clusterIndex
            }
        }
        return bestIndex
    }

    private func applying(_ upsert: PendingUpsert, to index: EmbeddingANNIndex) -> EmbeddingANNIndex {
        var index = index
        var existed = false
        for clusterIndex in index.clusters.indices {
            if let itemIndex = index.clusters[clusterIndex].items.firstIndex(where: { $0.snapshotId == upsert.snapshotId }) {
                index.clusters[clusterIndex].items.remove(at: itemIndex)
                existed = true
                break
            }
        }

        let posting = EmbeddingANNPostingEntry(snapshotId: upsert.snapshotId,
                                               startedAtMs: upsert.startedAtMs,
                                               appBundleId: upsert.appBundleId)
        let centroidIndex = nearestCentroidIndex(for: upsert.vector, index: index)
        index.clusters[centroidIndex].items.append(posting)
        index.clusters[centroidIndex].items.sort { lhs, rhs in
            if lhs.startedAtMs == rhs.startedAtMs {
                return lhs.snapshotId > rhs.snapshotId
            }
            return lhs.startedAtMs > rhs.startedAtMs
        }

        if !existed {
            index.metadata.embeddingCount += 1
        }
        index.metadata.maxUpdatedAtMs = max(index.metadata.maxUpdatedAtMs, upsert.updatedAtMs)
        index.metadata.clusterCount = index.clusters.count
        index.metadata.builtAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        return index
    }

    func loadIndexFromDisk(identity: VectorSearchIdentity, stats: EmbeddingStats) -> EmbeddingANNIndex? {
        guard let url = fileURL(for: identity) else { return nil }
        let payload: Data
        do {
            payload = try StoragePaths.withSecurityScope { try Data(contentsOf: url) }
        } catch {
            return nil
        }
        let decodedData: Data
        do {
            decodedData = try decodeIndexPayload(payload)
        } catch {
            removeIndexFile(for: identity)
            return nil
        }
        let decoder = PropertyListDecoder()
        guard let index = try? decoder.decode(EmbeddingANNIndex.self, from: decodedData),
              index.metadata.matches(identity: identity, stats: stats) else {
            removeIndexFile(for: identity)
            return nil
        }
        return index
    }

    func saveIndexSoon(_ index: EmbeddingANNIndex, identity: VectorSearchIdentity, delay: TimeInterval) {
        pendingSaves.removeValue(forKey: identity)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveIndex(index, identity: identity)
        }
        pendingSaves[identity] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func saveIndex(_ index: EmbeddingANNIndex, identity: VectorSearchIdentity) {
        pendingSaves.removeValue(forKey: identity)
        guard let url = fileURL(for: identity) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let plain = try? encoder.encode(index) else { return }
        let payload: Data
        if UserDefaults.standard.bool(forKey: "settings.vaultEnabled") {
            guard let encrypted = try? FileCrypter.shared.encryptData(plain, timestampMs: Int64(Date().timeIntervalSince1970 * 1000)) else {
                return
            }
            payload = encrypted
        } else {
            payload = plain
        }
        _ = try? StoragePaths.withSecurityScope {
            try StoragePaths.ensureRootExists()
            let dir = StoragePaths.vectorIndexDir()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let tmp = url.appendingPathExtension("tmp")
            try payload.write(to: tmp, options: .atomic)
            let _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        }
    }

    func decodeIndexPayload(_ payload: Data) throws -> Data {
        if payload.starts(with: Data("TSE1".utf8)) {
            return try FileCrypter.shared.decryptData(payload)
        }
        return payload
    }

    func fileURL(for identity: VectorSearchIdentity) -> URL? {
        StoragePaths.withSecurityScope {
            let dir = StoragePaths.vectorIndexDir()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let digest = SHA256.hash(data: Data(identity.cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
            return dir.appendingPathComponent("\(digest).anncache")
        }
    }

    func removeIndexFile(for identity: VectorSearchIdentity) {
        guard let url = fileURL(for: identity) else { return }
        _ = try? StoragePaths.withSecurityScope {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
