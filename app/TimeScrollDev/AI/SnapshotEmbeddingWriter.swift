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

    func storeCurrentEmbeddingIfNeeded(snapshotId: Int64, pixelBuffer: CVPixelBuffer, extractedText: String?) {
        let defaults = UserDefaults.standard
        let aiEnabled = defaults.bool(forKey: "settings.aiEmbeddingsEnabled")
        guard aiEnabled else { return }

        let service = EmbeddingService.shared
        service.reloadFromSettings()
        guard service.dim > 0 else { return }

        let vector = service.embedDocument(pixelBuffer: pixelBuffer, extractedText: extractedText)
        guard !vector.isEmpty else { return }

        do {
            let updatedAtMs = try DB.shared.upsertEmbedding(
                snapshotId: snapshotId,
                dim: vector.count,
                vec: vector,
                provider: service.providerID,
                model: service.modelID
            )
            if let meta = try? DB.shared.snapshotMetaById(snapshotId) {
                let identity = VectorSearchIdentity(provider: service.providerID,
                                                    model: service.modelID,
                                                    dim: vector.count,
                                                    dbPath: DB.shared.dbURL?.path ?? StoragePaths.dbURL().path)
                EmbeddingANNIndexStore.shared.recordUpsert(identity: identity,
                                                           snapshotId: snapshotId,
                                                           startedAtMs: meta.startedAtMs,
                                                           appBundleId: meta.appBundleId,
                                                           vector: vector,
                                                           updatedAtMs: updatedAtMs)
            }
            if defaults.bool(forKey: "settings.debugMode") {
                let head = vector.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                print("[AI][Store] snapshotId=\(snapshotId) provider=\(service.providerID) model=\(service.modelID) dim=\(vector.count) head=[\(head)]")
            }
        } catch {
            if defaults.bool(forKey: "settings.debugMode") {
                print("[AI][Store][Error] snapshotId=\(snapshotId) provider=\(service.providerID) model=\(service.modelID) err=\(error.localizedDescription)")
            }
        }
    }

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
        EmbeddingANNIndexStore.shared.invalidate(identity: identity)
        let rows = try DB.shared.listSnapshotsForEmbeddingRebuild()
        try DB.shared.deleteEmbeddings(provider: provider, model: model)

        var stored = 0
        for (index, row) in rows.enumerated() {
            autoreleasepool {
                let extractedText = try? DB.shared.textContent(snapshotId: row.id)
                if service.supportsImageDocuments {
                    if let pixelBuffer = SnapshotImageLoader.loadPixelBuffer(for: row) {
                        let vector = service.embedDocument(pixelBuffer: pixelBuffer, extractedText: extractedText ?? nil)
                        if !vector.isEmpty {
                            _ = try? DB.shared.upsertEmbedding(snapshotId: row.id, dim: vector.count, vec: vector, provider: provider, model: model)
                            stored += 1
                        }
                    }
                } else if let extractedText, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let vector = service.embed(extractedText, usage: .document)
                    if !vector.isEmpty {
                        _ = try? DB.shared.upsertEmbedding(snapshotId: row.id, dim: vector.count, vec: vector, provider: provider, model: model)
                        stored += 1
                    }
                }
            }
            progress(RebuildStatus(processed: index + 1, total: rows.count, stored: stored))
        }

        let stats = (try? DB.shared.embeddingStats(requireDim: service.dim,
                                                   requireProvider: provider,
                                                   requireModel: model)) ?? EmbeddingStats(count: 0, maxUpdatedAtMs: 0)
        EmbeddingANNIndexStore.shared.scheduleBuildIfNeeded(identity: identity, stats: stats)
    }
}
