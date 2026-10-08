import CoreVideo
import Foundation

final class SnapshotEmbeddingWriter {
    static let shared = SnapshotEmbeddingWriter()
    private init() {}

    struct RebuildStatus: Equatable, Sendable {
        let processed: Int
        let total: Int
        let stored: Int
    }

    /// Input for one live snapshot embedding. `image` is a small private copy of the frame,
    /// present only when the active model embeds images.
    struct Job {
        let snapshotId: Int64
        let image: CVPixelBuffer?
        let extractedText: String?
    }

    /// Embeds a batch of snapshots and stores the vectors in one transaction.
    func storeEmbeddings(for jobs: [Job]) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "settings.aiEmbeddingsEnabled"), !jobs.isEmpty else { return }

        let service = EmbeddingService.shared
        service.reloadFromSettings(onlyIfSelectionChanged: true)
        guard service.dim > 0 else { return }

        let embedded: [(snapshotId: Int64, embedding: EmbeddingService.DocumentEmbedding)] = jobs.compactMap { job in
            autoreleasepool {
                service.embedDocumentWithIdentity(pixelBuffer: job.image, extractedText: job.extractedText)
                    .map { (job.snapshotId, $0) }
            }
        }
        guard !embedded.isEmpty else { return }

        let stored: [(snapshotId: Int64, embedding: EmbeddingService.DocumentEmbedding, updatedAtMs: Int64)]
        do {
            stored = try DB.shared.withWriteSavepoint {
                try embedded.map { item in
                    let vector = item.embedding.vector
                    let updatedAtMs = try DB.shared.upsertEmbedding(snapshotId: item.snapshotId,
                                                                    dim: vector.count,
                                                                    vec: vector,
                                                                    provider: item.embedding.providerID,
                                                                    model: item.embedding.modelID)
                    return (item.snapshotId, item.embedding, updatedAtMs)
                }
            }
        } catch {
            if defaults.bool(forKey: "settings.debugMode") {
                print("[AI][Store][Error] batch=\(embedded.count) err=\(error.localizedDescription)")
            }
            return
        }

        let dbPath = DB.shared.dbURL?.path ?? StoragePaths.dbURL().path
        for item in stored {
            let vector = item.embedding.vector
            guard let meta = try? DB.shared.snapshotMetaById(item.snapshotId) else { continue }
            let identity = VectorSearchIdentity(provider: item.embedding.providerID,
                                                model: item.embedding.modelID,
                                                dim: vector.count,
                                                dbPath: dbPath)
            EmbeddingANNIndexStore.shared.recordUpsert(identity: identity,
                                                       snapshotId: item.snapshotId,
                                                       startedAtMs: meta.startedAtMs,
                                                       appBundleId: meta.appBundleId,
                                                       vector: vector,
                                                       updatedAtMs: item.updatedAtMs)
            EmbeddingMatrixStore.shared.recordUpsert(identity: identity, row: EmbeddingMatrixRow(
                snapshotId: item.snapshotId,
                startedAtMs: meta.startedAtMs,
                appBundleId: meta.appBundleId,
                captureKind: meta.captureKind,
                audioSourceKind: meta.audioSourceKind,
                vector: vector,
                updatedAtMs: item.updatedAtMs))
            if defaults.bool(forKey: "settings.debugMode") {
                let head = vector.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                print("[AI][Store] snapshotId=\(item.snapshotId) provider=\(item.embedding.providerID) model=\(item.embedding.modelID) dim=\(vector.count) head=[\(head)]")
            }
        }
    }

    private static let stagingModelSuffix = "#rebuild"

    func rebuildCurrentEmbeddings(progress: @escaping (RebuildStatus) -> Void) throws {
        let defaults = UserDefaults.standard
        let aiEnabled = defaults.bool(forKey: "settings.aiEmbeddingsEnabled")
        guard aiEnabled else {
            throw NSError(domain: "TimeScroll.AI", code: 40, userInfo: [NSLocalizedDescriptionKey: "Enable AI search before rebuilding embeddings."])
        }

        let service = EmbeddingService.shared
        service.reloadFromSettings()
        guard service.dim > 0 else {
            throw NSError(domain: "TimeScroll.AI", code: 41, userInfo: [NSLocalizedDescriptionKey: "The selected embedding model is not ready yet."])
        }

        let provider = service.providerID
        let model = service.modelID
        let identity = VectorSearchIdentity(provider: provider,
                                            model: model,
                                            dim: service.dim,
                                            dbPath: DB.shared.dbURL?.path ?? StoragePaths.dbURL().path)
        // Build into a staging model id so current vectors stay searchable during the rebuild
        // and survive an interrupted run; the staged set replaces them atomically at the end.
        let stagingModel = model + Self.stagingModelSuffix
        try DB.shared.deleteEmbeddings(provider: provider, model: stagingModel)
        let rows = try DB.shared.listSnapshotsForEmbeddingRebuild()

        var stored = 0
        for (index, row) in rows.enumerated() {
            autoreleasepool {
                let extractedText = try? DB.shared.textContent(snapshotId: row.id)
                if service.supportsImageDocuments, row.captureKind == .screen {
                    if let pixelBuffer = SnapshotImageLoader.loadPixelBuffer(for: row) {
                        let vector = service.embedDocument(pixelBuffer: pixelBuffer, extractedText: extractedText ?? nil)
                        if !vector.isEmpty {
                            _ = try? DB.shared.upsertEmbedding(snapshotId: row.id, dim: vector.count, vec: vector, provider: provider, model: stagingModel)
                            stored += 1
                        }
                    }
                } else if let extractedText, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let vector = service.embed(extractedText, usage: .document)
                    if !vector.isEmpty {
                        _ = try? DB.shared.upsertEmbedding(snapshotId: row.id, dim: vector.count, vec: vector, provider: provider, model: stagingModel)
                        stored += 1
                    }
                }
            }
            progress(RebuildStatus(processed: index + 1, total: rows.count, stored: stored))
        }

        try DB.shared.promoteStagedEmbeddings(provider: provider, stagingModel: stagingModel, model: model)
        EmbeddingANNIndexStore.shared.invalidate(identity: identity)

        let stats = (try? DB.shared.embeddingStats(requireDim: service.dim,
                                                   requireProvider: provider,
                                                   requireModel: model)) ?? EmbeddingStats(count: 0, maxUpdatedAtMs: 0)
        EmbeddingANNIndexStore.shared.scheduleBuildIfNeeded(identity: identity, stats: stats)
    }
}
