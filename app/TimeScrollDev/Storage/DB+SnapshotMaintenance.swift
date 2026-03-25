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
            _ = sqlite3_exec(db, "DELETE FROM ts_text;", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text_chunk;", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text_store;", nil, nil, nil)
            _ = sqlite3_exec(db, "UPDATE ts_snapshot SET text_ref_id=NULL, text_store_id=NULL;", nil, nil, nil)
        }
    }

    func purgeOlderThan(days: Int) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
            // Collect file paths to delete before removing DB rows
            var stmt: OpaquePointer?
            var pathsToHandle: [String] = []
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT path FROM ts_snapshot WHERE started_at_ms < ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, cutoff)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cstr = sqlite3_column_text(stmt, 0) {
                        pathsToHandle.append(String(cString: cstr))
                    }
                }
            }
            // Move each path to backup if enabled; otherwise delete.
            let fm = FileManager.default
            for p in pathsToHandle {
                let srcURL = URL(fileURLWithPath: p)
                let archived = StoragePaths.archiveSnapshotToBackupIfEnabled(srcURL)
                if !archived { _ = try? fm.removeItem(at: srcURL) }
            }

            // Delete from FTS and primary tables by cutoff
            let sql = """
            DELETE FROM ts_text WHERE rowid IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_text_chunk WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_ocr_boxes WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_embedding WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_snapshot WHERE started_at_ms < \(cutoff);
            DELETE FROM ts_text_store WHERE id NOT IN (SELECT DISTINCT text_store_id FROM ts_snapshot WHERE text_store_id IS NOT NULL);
            """
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    // Delete rows older than a specific cutoff, optionally skipping on-disk deletions.
    func purgeRowsOlderThan(cutoffMs cutoff: Int64, deleteFiles: Bool) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var pathsToHandle: [String] = []
            if deleteFiles {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                if sqlite3_prepare_v2(db, "SELECT path FROM ts_snapshot WHERE started_at_ms < ?;", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, cutoff)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let cstr = sqlite3_column_text(stmt, 0) {
                            pathsToHandle.append(String(cString: cstr))
                        }
                    }
                }
                let fm = FileManager.default
                for p in pathsToHandle {
                    let srcURL = URL(fileURLWithPath: p)
                    let archived = StoragePaths.archiveSnapshotToBackupIfEnabled(srcURL)
                    if !archived { _ = try? fm.removeItem(at: srcURL) }
                }
            }
            let sql = """
            DELETE FROM ts_text WHERE rowid IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_text_chunk WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_ocr_boxes WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_embedding WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
            DELETE FROM ts_snapshot WHERE started_at_ms < \(cutoff);
            DELETE FROM ts_text_store WHERE id NOT IN (SELECT DISTINCT text_store_id FROM ts_snapshot WHERE text_store_id IS NOT NULL);
            """
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
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
            _ = sqlite3_exec(db, "DELETE FROM ts_text WHERE rowid=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text_chunk WHERE snapshot_id=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_ocr_boxes WHERE snapshot_id=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_embedding WHERE snapshot_id=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_snapshot WHERE id=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_text_store WHERE id NOT IN (SELECT DISTINCT text_store_id FROM ts_snapshot WHERE text_store_id IS NOT NULL);", nil, nil, nil)
        }
    }
}
