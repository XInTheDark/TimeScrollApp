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
            _ = sqlite3_exec(db, "DELETE FROM ts_session_sketch; \(Self.allSessionDaysDeletionSQL)", nil, nil, nil)
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
            \(Self.orphanedSessionSketchDeletionSQL)
            DELETE FROM ts_session_day WHERE window_start_ms < \(cutoff);
            DELETE FROM ts_activity_session WHERE day_start_ms NOT IN (SELECT day_start_ms FROM ts_session_day);
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

    /// Deletes one snapshot row, then removes media no remaining row uses once the deletion is
    /// committed. A shared HEVC segment stays while other snapshots of its minute remain.
    func deleteSnapshot(id: Int64) throws {
        let files = try onQueueSync { () -> [String] in
            try openIfNeeded()
            guard let db = db else { return [] }

            var path: String?
            var thumbPath: String?
            var startedAtMs: Int64 = 0
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT path, thumb_path, started_at_ms FROM ts_snapshot WHERE id=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, id)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { path = String(cString: c) }
                    if let c = sqlite3_column_text(stmt, 1) { thumbPath = String(cString: c) }
                    startedAtMs = sqlite3_column_int64(stmt, 2)
                }
            }

            let sql = """
            BEGIN IMMEDIATE;
            \(Self.textIndexDeletionSQL(snapshotIdsSQL: "\(id)", legacyTablesExist: Self.legacyTextTablesExist(db: db)))
            \(Self.ocrLayoutDeletionSQL(snapshotIdsSQL: "\(id)"))
            DELETE FROM ts_embedding WHERE snapshot_id=\(id);
            DELETE FROM ts_snapshot WHERE id=\(id);
            DELETE FROM ts_text_store WHERE id NOT IN (SELECT DISTINCT text_store_id FROM ts_snapshot WHERE text_store_id IS NOT NULL);
            \(Self.orphanedSessionSketchDeletionSQL)
            \(Self.sessionDayInvalidationSQL(windowContaining: "\(startedAtMs)"))
            COMMIT;
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw NSError(domain: "TS.DB", code: 81, userInfo: [NSLocalizedDescriptionKey: message])
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            return DeletedSnapshotMedia.filesToRemove(path: path, thumbPath: thumbPath, startedAtMs: startedAtMs, nowMs: nowMs) { file in
                // Unknown (query failed) counts as referenced, so the file is kept.
                isMediaReferenced(DeletedSnapshotMedia.equivalentPaths(of: file), db: db) ?? true
            }
        }
        let fm = FileManager.default
        for file in files { _ = try? fm.removeItem(atPath: file) }
        purgeOrphanedAudioAssets()
    }

    /// Whether any remaining row uses one of `paths` as its media or thumbnail; nil if the query fails.
    private func isMediaReferenced(_ paths: [String], db: OpaquePointer) -> Bool? {
        let placeholders = paths.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT 1 FROM ts_snapshot WHERE path IN (\(placeholders)) OR thumb_path IN (\(placeholders)) LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (offset, path) in (paths + paths).enumerated() {
            sqlite3_bind_text(stmt, Int32(offset + 1), path, -1, SQLITE_TRANSIENT)
        }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: return nil
        }
    }
}
