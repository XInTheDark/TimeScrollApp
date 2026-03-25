import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    func pathsOlderThan(cutoffMs: Int64) throws -> [String] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT path FROM ts_snapshot WHERE started_at_ms < ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            var paths: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    paths.append(String(cString: c))
                }
            }
            return paths
        }
    }

    func findMetaByPath(_ path: String) throws -> (startedAtMs: Int64, appBundleId: String?)? {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT started_at_ms, app_bundle_id FROM ts_snapshot WHERE path=? LIMIT 1;", -1, &stmt, nil) != SQLITE_OK {
                return nil
            }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_int64(stmt, 0)
                let bptr = sqlite3_column_text(stmt, 1)
                let bid = bptr != nil ? String(cString: bptr!) : nil
                return (ts, bid)
            }
            return nil
        }
    }

    // Zero-based index of the snapshot within the current filtered ordering (DESC by time)
    func rankOfSnapshot(path: String, appBundleId: String? = nil, startMs: Int64? = nil, endMs: Int64? = nil) throws -> Int? {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return nil }
            // Fetch the target timestamp
            var tstmt: OpaquePointer?
            defer { sqlite3_finalize(tstmt) }
            if sqlite3_prepare_v2(db, "SELECT started_at_ms FROM ts_snapshot WHERE path=? LIMIT 1;", -1, &tstmt, nil) != SQLITE_OK {
                return nil
            }
            sqlite3_bind_text(tstmt, 1, path, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(tstmt) == SQLITE_ROW else { return nil }
            let targetTs = sqlite3_column_int64(tstmt, 0)

            var sql = "SELECT COUNT(*) FROM ts_snapshot WHERE 1=1"
            if let s = startMs { sql += " AND started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND started_at_ms <= \(e)" }
            if appBundleId != nil { sql += " AND app_bundle_id = ?" }
            sql += " AND started_at_ms > ?;" // Items strictly newer than target

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return nil }
            var idx: Int32 = 1
            if let bid = appBundleId { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_int64(stmt, idx, targetTs)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func distinctApps() throws -> [(bundleId: String, name: String)] {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // Use latest observed app_name per bundle id for better label accuracy
        let sql = """
        SELECT s.app_bundle_id,
               (
                   SELECT s2.app_name
                   FROM ts_snapshot s2
                   WHERE s2.app_bundle_id = s.app_bundle_id AND s2.app_name IS NOT NULL
                   ORDER BY s2.started_at_ms DESC
                   LIMIT 1
               ) AS name
        FROM ts_snapshot s
        WHERE s.app_bundle_id IS NOT NULL
        GROUP BY s.app_bundle_id
        ORDER BY COALESCE(name, s.app_bundle_id);
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return []
        }
        var result: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let bidC = sqlite3_column_text(stmt, 0) {
                let bid = String(cString: bidC)
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? bid
                result.append((bid, name))
            }
        }
        return result
        }
    }

    struct SnapshotRow: Identifiable, Hashable { let id: Int64; let startedAtMs: Int64; let path: String }
    struct EmbeddingRebuildRow: Identifiable, Hashable {
        let id: Int64
        let startedAtMs: Int64
        let path: String
        let thumbPath: String?
    }

    func listSnapshots(limit: Int = 50) throws -> [SnapshotRow] {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT id, started_at_ms, path FROM ts_snapshot ORDER BY started_at_ms DESC LIMIT ?;", -1, &stmt, nil) != SQLITE_OK {
            return []
        }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [SnapshotRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_int64(stmt, 1)
            let path = String(cString: sqlite3_column_text(stmt, 2))
            rows.append(SnapshotRow(id: id, startedAtMs: ts, path: path))
        }
        return rows
        }
    }

    func listPlaintextSnapshots(limit: Int = 10_000) throws -> [SnapshotRow] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, started_at_ms, path FROM ts_snapshot WHERE path NOT LIKE '%.tse' ORDER BY started_at_ms ASC LIMIT ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var rows: [SnapshotRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                rows.append(SnapshotRow(id: id, startedAtMs: ts, path: path))
            }
            return rows
        }
    }

    func listSnapshotsForEmbeddingRebuild() throws -> [EmbeddingRebuildRow] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, started_at_ms, path, thumb_path FROM ts_snapshot ORDER BY started_at_ms ASC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var rows: [EmbeddingRebuildRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let startedAtMs = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let thumbPath = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                rows.append(EmbeddingRebuildRow(id: id, startedAtMs: startedAtMs, path: path, thumbPath: thumbPath))
            }
            return rows
        }
    }

}
