import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

struct EmbeddingStats: Hashable {
    let count: Int
    let maxUpdatedAtMs: Int64
}

struct EmbeddingIndexEntry: Hashable {
    let snapshotId: Int64
    let startedAtMs: Int64
    let appBundleId: String?
    let vector: [Float]
}

struct EmbeddingCandidate: Hashable {
    let result: SearchResult
    let vector: [Float]
    let dim: Int
}

extension DB {
    // MARK: - Embeddings

    @discardableResult
    func upsertEmbedding(snapshotId: Int64, dim: Int, vec: [Float], provider: String, model: String) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { throw NSError(domain: "TS.DB", code: 190, userInfo: [NSLocalizedDescriptionKey: "db is nil"]) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT INTO ts_embedding(snapshot_id, dim, vec, updated_at_ms, provider, model) VALUES(?, ?, ?, ?, ?, ?)\n                       ON CONFLICT(snapshot_id, provider, model) DO UPDATE SET dim=excluded.dim, vec=excluded.vec, updated_at_ms=excluded.updated_at_ms;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "TS.DB", code: 191, userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(msg)"])
            }
            sqlite3_bind_int64(stmt, 1, snapshotId)
            sqlite3_bind_int(stmt, 2, Int32(dim))
            // Store as raw Float32 contiguous data
            let data = vec.withUnsafeBufferPointer { Data(buffer: $0) }
            _ = data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            sqlite3_bind_int64(stmt, 4, nowMs)
            sqlite3_bind_text(stmt, 5, provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, model, -1, SQLITE_TRANSIENT)
            let step = sqlite3_step(stmt)
            if step != SQLITE_DONE {
                let msg = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "TS.DB", code: 192, userInfo: [NSLocalizedDescriptionKey: "step failed: \(step) \(msg)"])
            }
            return nowMs
        }
    }

    func deleteEmbeddings(provider: String, model: String) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "DELETE FROM ts_embedding WHERE provider = ? AND model = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, model, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    func embeddingCount(provider: String, model: String) throws -> Int {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT COUNT(*) FROM ts_embedding WHERE provider = ? AND model = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, model, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Lightweight counts for embedding availability. Used for debugging AI search filters.
    func embeddingCandidateCounts(requireDim: Int?, requireProvider: String?, requireModel: String?) throws -> (total: Int, dimOnly: Int, dimProviderModel: Int) {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return (0, 0, 0) }

            func count(_ sql: String, _ binds: ((OpaquePointer?) -> Void)? = nil) -> Int {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
                binds?(stmt)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    return Int(sqlite3_column_int64(stmt, 0))
                }
                return 0
            }

            let total = count("SELECT COUNT(*) FROM ts_embedding;")

            let dimOnly: Int
            if let dim = requireDim {
                dimOnly = count("SELECT COUNT(*) FROM ts_embedding WHERE dim = ?;") { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(dim))
                }
            } else {
                dimOnly = total
            }

            let dimProviderModel: Int
            if let dim = requireDim, let prov = requireProvider, let model = requireModel {
                dimProviderModel = count("SELECT COUNT(*) FROM ts_embedding WHERE dim = ? AND provider = ? AND model = ?;") { stmt in
                    sqlite3_bind_int(stmt, 1, Int32(dim))
                    sqlite3_bind_text(stmt, 2, prov, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, model, -1, SQLITE_TRANSIENT)
                }
            } else {
                dimProviderModel = dimOnly
            }

            return (total, dimOnly, dimProviderModel)
        }
    }

    func embeddingStats(requireDim: Int, requireProvider: String, requireModel: String) throws -> EmbeddingStats {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return EmbeddingStats(count: 0, maxUpdatedAtMs: 0) }
            let sql = """
            SELECT COUNT(*), COALESCE(MAX(e.updated_at_ms), 0)
            FROM ts_embedding e
            JOIN ts_snapshot s ON s.id = e.snapshot_id
            WHERE e.dim = ? AND e.provider = ? AND e.model = ?;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return EmbeddingStats(count: 0, maxUpdatedAtMs: 0)
            }
            sqlite3_bind_int(stmt, 1, Int32(requireDim))
            sqlite3_bind_text(stmt, 2, requireProvider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, requireModel, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return EmbeddingStats(count: 0, maxUpdatedAtMs: 0)
            }
            return EmbeddingStats(
                count: Int(sqlite3_column_int64(stmt, 0)),
                maxUpdatedAtMs: sqlite3_column_int64(stmt, 1)
            )
        }
    }

    func embeddingIndexEntries(requireDim: Int, requireProvider: String, requireModel: String) throws -> [EmbeddingIndexEntry] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            let sql = """
            SELECT s.id, s.started_at_ms, s.app_bundle_id, e.vec, e.dim
            FROM ts_embedding e
            JOIN ts_snapshot s ON s.id = e.snapshot_id
            WHERE e.dim = ? AND e.provider = ? AND e.model = ?
            ORDER BY s.started_at_ms DESC;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(requireDim))
            sqlite3_bind_text(stmt, 2, requireProvider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, requireModel, -1, SQLITE_TRANSIENT)
            var rows: [EmbeddingIndexEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let snapshotId = sqlite3_column_int64(stmt, 0)
                let startedAtMs = sqlite3_column_int64(stmt, 1)
                let appBundleId = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let blobPtr = sqlite3_column_blob(stmt, 3)
                let blobLen = Int(sqlite3_column_bytes(stmt, 3))
                let dim = Int(sqlite3_column_int(stmt, 4))
                guard let ptr = blobPtr, blobLen >= dim * MemoryLayout<Float>.size else { continue }
                let count = blobLen / MemoryLayout<Float>.size
                let vector = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
                rows.append(EmbeddingIndexEntry(snapshotId: snapshotId,
                                                startedAtMs: startedAtMs,
                                                appBundleId: appBundleId,
                                                vector: vector))
            }
            return rows
        }
    }

    /// Returns counts of embeddings grouped by model for the given provider+dim. Used to detect mismatched model strings.
    func embeddingModelStats(requireDim: Int, requireProvider: String) throws -> [(model: String, count: Int)] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            let sql = "SELECT model, COUNT(*) FROM ts_embedding WHERE dim = ? AND provider = ? GROUP BY model ORDER BY COUNT(*) DESC;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(requireDim))
            sqlite3_bind_text(stmt, 2, requireProvider, -1, SQLITE_TRANSIENT)
            var out: [(String, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let model = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let count = Int(sqlite3_column_int64(stmt, 1))
                out.append((model, count))
            }
            return out
        }
    }

    func embeddingCandidates(appBundleIds: [String]? = nil,
                              startMs: Int64? = nil,
                              endMs: Int64? = nil,
                              limit: Int = 2000,
                              offset: Int = 0,
                              requireDim: Int,
                              requireProvider: String,
                              requireModel: String) throws -> [EmbeddingCandidate] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, e.vec, e.dim
            FROM ts_embedding e
            JOIN ts_snapshot s ON s.id = e.snapshot_id
            WHERE e.dim = ? AND e.provider = ? AND e.model = ?
            """
            if let s = startMs { sql += " AND s.started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND s.started_at_ms <= \(e)" }
            if let ids = appBundleIds, !ids.isEmpty {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                sql += " AND s.app_bundle_id IN (\(placeholders))"
            }
            sql += " ORDER BY s.started_at_ms DESC LIMIT ? OFFSET ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            sqlite3_bind_int(stmt, idx, Int32(requireDim)); idx += 1
            sqlite3_bind_text(stmt, idx, requireProvider, -1, SQLITE_TRANSIENT); idx += 1
            sqlite3_bind_text(stmt, idx, requireModel, -1, SQLITE_TRANSIENT); idx += 1
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [EmbeddingCandidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                // vec blob
                let blobPtr = sqlite3_column_blob(stmt, 6)
                let blobLen = Int(sqlite3_column_bytes(stmt, 6))
                let dim = Int(sqlite3_column_int(stmt, 7))
                var vector: [Float] = []
                if let ptr = blobPtr, blobLen >= dim * MemoryLayout<Float>.size {
                    let count = blobLen / MemoryLayout<Float>.size
                    vector = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
                }
                let res = SearchResult(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name, thumbPath: thumb, content: "")
                rows.append(EmbeddingCandidate(result: res, vector: vector, dim: dim))
            }
            return rows
        }
    }

    func embeddingCandidates(snapshotIds: [Int64],
                             requireDim: Int,
                             requireProvider: String,
                             requireModel: String) throws -> [EmbeddingCandidate] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db, !snapshotIds.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: snapshotIds.count).joined(separator: ",")
            let sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, e.vec, e.dim
            FROM ts_embedding e
            JOIN ts_snapshot s ON s.id = e.snapshot_id
            WHERE e.dim = ? AND e.provider = ? AND e.model = ? AND s.id IN (\(placeholders))
            ORDER BY s.started_at_ms DESC;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            sqlite3_bind_int(stmt, idx, Int32(requireDim)); idx += 1
            sqlite3_bind_text(stmt, idx, requireProvider, -1, SQLITE_TRANSIENT); idx += 1
            sqlite3_bind_text(stmt, idx, requireModel, -1, SQLITE_TRANSIENT); idx += 1
            for snapshotId in snapshotIds {
                sqlite3_bind_int64(stmt, idx, snapshotId)
                idx += 1
            }
            var rows: [EmbeddingCandidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let blobPtr = sqlite3_column_blob(stmt, 6)
                let blobLen = Int(sqlite3_column_bytes(stmt, 6))
                let dim = Int(sqlite3_column_int(stmt, 7))
                var vector: [Float] = []
                if let ptr = blobPtr, blobLen >= dim * MemoryLayout<Float>.size {
                    let count = blobLen / MemoryLayout<Float>.size
                    vector = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
                }
                let result = SearchResult(id: id,
                                          startedAtMs: ts,
                                          path: path,
                                          appBundleId: bid,
                                          appName: name,
                                          thumbPath: thumb,
                                          content: "")
                rows.append(EmbeddingCandidate(result: result, vector: vector, dim: dim))
            }
            return rows
        }
    }
}
