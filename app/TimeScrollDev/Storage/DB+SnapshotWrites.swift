import Foundation
import CoreGraphics
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    func insertSnapshot(
        startedAtMs: Int64,
        path: String,
        text: String,
        appBundleId: String?,
        appName: String?,
        boxes: [OCRLine] = [],
        bytes: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        format: String? = nil,
        hash64: Int64? = nil,
        thumbPath: String? = nil,
        textRefId: Int64? = nil
    ) throws -> Int64 {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { throw NSError(domain: "TS.DB", code: 3) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT INTO ts_snapshot(started_at_ms, path, app_bundle_id, app_name, bytes, width, height, format, hash64, thumb_path, text_ref_id)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw NSError(domain: "TS.DB", code: 4)
        }
        sqlite3_bind_int64(stmt, 1, startedAtMs)
        sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
        if let b = appBundleId { sqlite3_bind_text(stmt, 3, b, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        if let n = appName { sqlite3_bind_text(stmt, 4, n, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
        if let v = bytes { sqlite3_bind_int64(stmt, 5, v) } else { sqlite3_bind_null(stmt, 5) }
        if let v = width { sqlite3_bind_int(stmt, 6, Int32(v)) } else { sqlite3_bind_null(stmt, 6) }
        if let v = height { sqlite3_bind_int(stmt, 7, Int32(v)) } else { sqlite3_bind_null(stmt, 7) }
        if let v = format { sqlite3_bind_text(stmt, 8, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
        if let v = hash64 { sqlite3_bind_int64(stmt, 9, v) } else { sqlite3_bind_null(stmt, 9) }
        if let v = thumbPath { sqlite3_bind_text(stmt, 10, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 10) }
        if let v = textRefId { sqlite3_bind_int64(stmt, 11, v) } else { sqlite3_bind_null(stmt, 11) }
        if sqlite3_step(stmt) != SQLITE_DONE { throw NSError(domain: "TS.DB", code: 5) }
        let rowId = sqlite3_last_insert_rowid(db)
        var tstmt: OpaquePointer?
        defer { sqlite3_finalize(tstmt) }
        if sqlite3_prepare_v2(db, "INSERT INTO ts_text(rowid, content) VALUES(?, ?);", -1, &tstmt, nil) != SQLITE_OK {
            throw NSError(domain: "TS.DB", code: 6)
        }
        let preview = (textRefId == nil && !text.isEmpty) ? IndexedTextProjection.preview(from: text) : ""
        sqlite3_bind_int64(tstmt, 1, rowId)
        sqlite3_bind_text(tstmt, 2, preview, -1, SQLITE_TRANSIENT)
        if sqlite3_step(tstmt) != SQLITE_DONE { throw NSError(domain: "TS.DB", code: 7) }

        if !boxes.isEmpty {
            var bstmt: OpaquePointer?
            defer { sqlite3_finalize(bstmt) }
            if sqlite3_prepare_v2(db, "INSERT INTO ts_ocr_boxes(snapshot_id, text, x, y, w, h) VALUES(?, ?, ?, ?, ?, ?);", -1, &bstmt, nil) != SQLITE_OK {
                return rowId
            }
            for box in boxes {
                sqlite3_bind_int64(bstmt, 1, rowId)
                sqlite3_bind_text(bstmt, 2, box.text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(bstmt, 3, Double(box.box.origin.x))
                sqlite3_bind_double(bstmt, 4, Double(box.box.origin.y))
                sqlite3_bind_double(bstmt, 5, Double(box.box.size.width))
                sqlite3_bind_double(bstmt, 6, Double(box.box.size.height))
                _ = sqlite3_step(bstmt)
                sqlite3_reset(bstmt)
            }
        }
        if !text.isEmpty {
            try updateFTS(rowId: rowId, content: text)
        }
        return rowId
        }
    }

    func updateSnapshotMeta(path: String, bytes: Int64?, width: Int?, height: Int?, format: String?) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var sets: [String] = []
            if bytes != nil { sets.append("bytes=?") }
            if width != nil { sets.append("width=?") }
            if height != nil { sets.append("height=?") }
            if format != nil { sets.append("format=?") }
            guard !sets.isEmpty else { return }
            let sql = "UPDATE ts_snapshot SET \(sets.joined(separator: ", ")) WHERE path=?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
            var idx: Int32 = 1
            if let v = bytes { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            if let v = width { sqlite3_bind_int(stmt, idx, Int32(v)); idx += 1 }
            if let v = height { sqlite3_bind_int(stmt, idx, Int32(v)); idx += 1 }
            if let v = format { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_text(stmt, idx, path, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    func updateSnapshotPath(oldPath: String, newPath: String, bytes: Int64?, format: String?) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var sets: [String] = ["path=?"]
            if bytes != nil { sets.append("bytes=?") }
            if format != nil { sets.append("format=?") }
            let sql = "UPDATE ts_snapshot SET \(sets.joined(separator: ", ")) WHERE path=?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
            var idx: Int32 = 1
            sqlite3_bind_text(stmt, idx, newPath, -1, SQLITE_TRANSIENT); idx += 1
            if let v = bytes { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            if let v = format { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_text(stmt, idx, oldPath, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    /// Update all snapshot path/thumb_path values that live under `oldRoot` to point to `newRoot`.
    /// This is used after transferring files to a different storage root so DB rows continue
    /// to reference the actual on-disk locations.
    func updateSnapshotPathsAfterRootMove(oldRoot: String, newRoot: String) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }

            // Normalize roots to exact prefixes so REPLACE works correctly
            let oldPrefix = oldRoot.hasSuffix("/") ? oldRoot : (oldRoot + "/")
            let newPrefix = newRoot.hasSuffix("/") ? newRoot : (newRoot + "/")

            // Update path and thumb_path using a helper to avoid duplication
            let changed1 = Self.replacePrefixInColumn(db: db, column: "path", oldPrefix: oldPrefix, newPrefix: newPrefix)
            _ = Self.replacePrefixInColumn(db: db, column: "thumb_path", oldPrefix: oldPrefix, newPrefix: newPrefix)
            fputs("[DB] updateSnapshotPathsAfterRootMove changed path/thumb entries: \(changed1)\n", stderr)
        }
    }

    /// Helper: run REPLACE on a specific column where the column value begins with oldPrefix.
    /// Returns number of rows changed by the UPDATE.
    private static func replacePrefixInColumn(db: OpaquePointer, column: String, oldPrefix: String, newPrefix: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "UPDATE ts_snapshot SET \(column) = REPLACE(\(column), ?, ?) WHERE \(column) LIKE ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, oldPrefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, newPrefix, -1, SQLITE_TRANSIENT)
        let likePat = (oldPrefix + "%")
        sqlite3_bind_text(stmt, 3, likePat, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        return Int(sqlite3_changes(db))
    }

    /// Scan all snapshots and rewrite any `path`/`thumb_path` entries that are not
    /// under the current `StoragePaths.snapshotsDir()` root to use the current root.
    /// Returns the number of rows updated (path + thumb updates counted separately).
    func updateSnapshotPathsToCurrentRoot() -> Int {
        return (try? onQueueSync { () -> Int in
            try openIfNeeded()
            guard let db = db else { return 0 }

            let snapshotsDirPath = StoragePaths.snapshotsDir().path

            // Select id, path, thumb_path
            var selStmt: OpaquePointer?
            defer { sqlite3_finalize(selStmt) }
            if sqlite3_prepare_v2(db, "SELECT id, path, thumb_path FROM ts_snapshot;", -1, &selStmt, nil) != SQLITE_OK { return 0 }

            // Prepare update statements by id
            var updPathStmt: OpaquePointer?
            var updThumbStmt: OpaquePointer?
            defer { sqlite3_finalize(updPathStmt); sqlite3_finalize(updThumbStmt) }
            let updPathSQL = "UPDATE ts_snapshot SET path=? WHERE id=?;"
            let updThumbSQL = "UPDATE ts_snapshot SET thumb_path=? WHERE id=?;"
            _ = sqlite3_prepare_v2(db, updPathSQL, -1, &updPathStmt, nil)
            _ = sqlite3_prepare_v2(db, updThumbSQL, -1, &updThumbStmt, nil)

            var changed = 0

            while sqlite3_step(selStmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(selStmt, 0)
                guard let cpath = sqlite3_column_text(selStmt, 1) else { continue }
                let path = String(cString: cpath)
                var thumb: String? = nil
                if let cthumb = sqlite3_column_text(selStmt, 2) { thumb = String(cString: cthumb) }

                // If path not already under current snapshots dir, try to rewrite it.
                if !path.hasPrefix(snapshotsDirPath) {
                    var newPath: String? = nil
                    if let r = path.range(of: "/Snapshots/") {
                        let suffix = String(path[r.upperBound...])
                        newPath = (snapshotsDirPath as NSString).appendingPathComponent(suffix)
                    } else if let r = path.range(of: "Snapshots/") {
                        let suffix = String(path[r.upperBound...])
                        newPath = (snapshotsDirPath as NSString).appendingPathComponent(suffix)
                    } else {
                        // Fallback: move by filename into snapshots root
                        let filename = URL(fileURLWithPath: path).lastPathComponent
                        newPath = (snapshotsDirPath as NSString).appendingPathComponent(filename)
                    }
                    if let np = newPath {
                        if sqlite3_bind_text(updPathStmt, 1, np, -1, SQLITE_TRANSIENT) == SQLITE_OK && sqlite3_bind_int64(updPathStmt, 2, id) == SQLITE_OK {
                            _ = sqlite3_step(updPathStmt)
                            sqlite3_reset(updPathStmt)
                            changed += 1
                        }
                    }
                }

                // Thumb handling
                if let t = thumb, !t.hasPrefix(snapshotsDirPath) {
                    var newThumb: String? = nil
                    if let r = t.range(of: "/Snapshots/") {
                        let suffix = String(t[r.upperBound...])
                        newThumb = (snapshotsDirPath as NSString).appendingPathComponent(suffix)
                    } else if let r = t.range(of: "Snapshots/") {
                        let suffix = String(t[r.upperBound...])
                        newThumb = (snapshotsDirPath as NSString).appendingPathComponent(suffix)
                    } else {
                        let filename = URL(fileURLWithPath: t).lastPathComponent
                        newThumb = (snapshotsDirPath as NSString).appendingPathComponent(filename)
                    }
                    if let nt = newThumb {
                        if sqlite3_bind_text(updThumbStmt, 1, nt, -1, SQLITE_TRANSIENT) == SQLITE_OK && sqlite3_bind_int64(updThumbStmt, 2, id) == SQLITE_OK {
                            _ = sqlite3_step(updThumbStmt)
                            sqlite3_reset(updThumbStmt)
                            changed += 1
                        }
                    }
                }
            }

            return changed
        }) ?? 0 }

}
