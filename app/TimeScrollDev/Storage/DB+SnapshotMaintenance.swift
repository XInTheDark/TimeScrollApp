import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    func clearFTS() throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            _ = sqlite3_exec(db, "INSERT INTO ts_text_index(ts_text_index) VALUES('delete-all');", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text;", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text_chunk;", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text_store;", nil, nil, nil)
            _ = sqlite3_exec(db, "UPDATE ts_snapshot SET text_ref_id=NULL, text_store_id=NULL;", nil, nil, nil)
        }
    }

    /// Deletes rows older than `days`, then removes their media once the deletion is committed.
    /// Returns the number of snapshot rows removed.
    @discardableResult
    func purgeOlderThan(days: Int) throws -> Int {
        let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
        let (removedRows, unreferencedPaths) = try onQueueSync { () -> (Int, [String]) in
            try openIfNeeded()
            guard let db = db else { return (0, []) }
            var candidates = Set<String>()
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT path, thumb_path FROM ts_snapshot WHERE started_at_ms < ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, cutoff)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { candidates.insert(String(cString: c)) }
                    if let c = sqlite3_column_text(stmt, 1) { candidates.insert(String(cString: c)) }
                }
            }
            guard !candidates.isEmpty else { return (0, []) }

            let expiredIds = "SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff)"
            let textDeletes = Self.textIndexDeletionSQL(snapshotIdsSQL: expiredIds, legacyTablesExist: Self.legacyTextTablesExist(db: db))
            let sql = """
            BEGIN IMMEDIATE;
            \(textDeletes)
            \(Self.ocrLayoutDeletionSQL(snapshotIdsSQL: expiredIds))
            DELETE FROM ts_embedding WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_snapshot WHERE started_at_ms < \(cutoff);
            DELETE FROM ts_text_store WHERE id NOT IN (SELECT DISTINCT text_store_id FROM ts_snapshot WHERE text_store_id IS NOT NULL);
            COMMIT;
            """
            let before = sqlite3_total_changes(db)
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw NSError(domain: "TS.DB", code: 80, userInfo: [NSLocalizedDescriptionKey: message])
            }
            let removed = Int(sqlite3_total_changes(db) - before)
            // A 60 s HEVC segment can straddle the cutoff; keep media still referenced by newer rows.
            let stillReferenced = mediaPathsReferenced(fromMs: cutoff, toMs: cutoff + 5 * 60_000, db: db)
            return (removed, Array(candidates.subtracting(stillReferenced)))
        }
        let fm = FileManager.default
        for path in unreferencedPaths {
            let url = URL(fileURLWithPath: path)
            if !StoragePaths.archiveSnapshotToBackupIfEnabled(url) { _ = try? fm.removeItem(at: url) }
        }
        purgeOrphanedAudioAssets()
        return removedRows
    }

    private func mediaPathsReferenced(fromMs: Int64, toMs: Int64, db: OpaquePointer) -> Set<String> {
        var referenced = Set<String>()
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT path, thumb_path FROM ts_snapshot WHERE started_at_ms >= ? AND started_at_ms < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return referenced }
        sqlite3_bind_int64(stmt, 1, fromMs)
        sqlite3_bind_int64(stmt, 2, toMs)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { referenced.insert(String(cString: c)) }
            if let c = sqlite3_column_text(stmt, 1) { referenced.insert(String(cString: c)) }
        }
        return referenced
    }

    func deleteSnapshot(id: Int64) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }

            // Lookup file path (and optional thumb path) before deleting rows
            var pStmt: OpaquePointer?
            defer { sqlite3_finalize(pStmt) }
            var pathToDelete: String? = nil
            var thumbToDelete: String? = nil
            if sqlite3_prepare_v2(db, "SELECT path, thumb_path FROM ts_snapshot WHERE id=? LIMIT 1;", -1, &pStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(pStmt, 1, id)
                if sqlite3_step(pStmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(pStmt, 0) { pathToDelete = String(cString: c) }
                    if let c2 = sqlite3_column_text(pStmt, 1) { thumbToDelete = String(cString: c2) }
                }
            }

            // Best-effort file deletions
            let fm = FileManager.default
            if let p = pathToDelete { _ = try? fm.removeItem(atPath: p) }
            if let t = thumbToDelete { _ = try? fm.removeItem(atPath: t) }

            // Delete associated text and boxes, then primary row
            _ = sqlite3_exec(db, Self.textIndexDeletionSQL(snapshotIdsSQL: "\(id)", legacyTablesExist: Self.legacyTextTablesExist(db: db)), nil, nil, nil)
            _ = sqlite3_exec(db, Self.ocrLayoutDeletionSQL(snapshotIdsSQL: "\(id)"), nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_embedding WHERE snapshot_id=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_snapshot WHERE id=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text_store WHERE id NOT IN (SELECT DISTINCT text_store_id FROM ts_snapshot WHERE text_store_id IS NOT NULL);", nil, nil, nil)
            purgeOrphanedAudioAssets()
        }
    }
}
