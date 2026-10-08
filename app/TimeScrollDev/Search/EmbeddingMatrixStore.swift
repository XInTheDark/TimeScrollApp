import Foundation

/// Holds the `EmbeddingMatrix` for the active embedding identity. Loaded on first search,
/// kept current by capture-time upserts, rebuilt when the database diverges (e.g. after
/// retention), and released after a short idle period or when the vault locks.
final class EmbeddingMatrixStore {
    static let shared = EmbeddingMatrixStore()
    private init() {}

    private static let idleEvictionSeconds: TimeInterval = 120
    private static let loadBatchSize = 4096

    private let lock = NSLock()
    // Upserts that arrive while a search or load holds `lock`; applied on the next access so
    // capture threads never wait for a matrix load.
    private let pendingLock = NSLock()
    private var pendingUpserts: [(VectorSearchIdentity, EmbeddingMatrixRow)] = []
    private var identity: VectorSearchIdentity?
    private var matrix: EmbeddingMatrix?
    private var evictWork: DispatchWorkItem?

    /// Runs `body` with an up-to-date matrix for `identity`, loading it if needed.
    func withMatrix<T>(identity: VectorSearchIdentity, stats: EmbeddingStats, _ body: (EmbeddingMatrix) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        applyPendingUpserts()
        if self.identity != identity || matrix?.stats != stats {
            matrix = load(identity: identity)
            self.identity = identity
        }
        scheduleEviction()
        guard let matrix, matrix.rowCount > 0 else { return nil }
        return body(matrix)
    }

    func recordUpsert(identity: VectorSearchIdentity, row: EmbeddingMatrixRow) {
        guard lock.try() else {
            pendingLock.lock()
            pendingUpserts.append((identity, row))
            pendingLock.unlock()
            return
        }
        defer { lock.unlock() }
        applyPendingUpserts()
        guard self.identity == identity, let matrix else { return }
        matrix.upsert(row)
    }

    // Must be called with `lock` held.
    private func applyPendingUpserts() {
        pendingLock.lock()
        let pending = pendingUpserts
        pendingUpserts.removeAll()
        pendingLock.unlock()
        guard let matrix, let identity else { return }
        for (rowIdentity, row) in pending where rowIdentity == identity {
            matrix.upsert(row)
        }
    }

    func clearMemory() {
        lock.lock()
        defer { lock.unlock() }
        evictWork?.cancel()
        evictWork = nil
        matrix = nil
        identity = nil
        pendingLock.lock()
        pendingUpserts.removeAll()
        pendingLock.unlock()
    }

    private func load(identity: VectorSearchIdentity) -> EmbeddingMatrix? {
        let matrix = EmbeddingMatrix(dim: identity.dim)
        var afterRowId: Int64 = 0
        while true {
            guard let batch = try? DB.shared.embeddingMatrixRows(provider: identity.provider,
                                                                 model: identity.model,
                                                                 dim: identity.dim,
                                                                 afterRowId: afterRowId,
                                                                 limit: Self.loadBatchSize) else { return nil }
            for row in batch.rows { matrix.upsert(row) }
            guard let last = batch.lastRowId, batch.rows.count == Self.loadBatchSize else { break }
            afterRowId = last
        }
        return matrix
    }

    // Must be called with `lock` held.
    private func scheduleEviction() {
        evictWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clearMemory() }
        evictWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleEvictionSeconds, execute: work)
    }
}
