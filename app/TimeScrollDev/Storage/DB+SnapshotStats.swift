import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    func avgSnapshotBytes() throws -> Int64 {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT AVG(bytes) FROM ts_snapshot WHERE bytes IS NOT NULL;", -1, &stmt, nil) != SQLITE_OK { return 0 }
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
        }
    }

    func snapshotCount() throws -> Int {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ts_snapshot;", -1, &stmt, nil) != SQLITE_OK { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func snapshotCountSince(ms cutoffMs: Int64) throws -> Int {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ts_snapshot WHERE started_at_ms >= ?;", -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    // Best-effort accurate byte sums, deduped by path and
    // falling back to on-disk size when DB bytes are missing/zero (e.g., HEVC during open segments).
    func sumSnapshotBytesAll() throws -> Int64 {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            // Deduplicate by path; take max recorded bytes for that path.
            let sql = "SELECT path, MAX(COALESCE(bytes, 0)) AS b FROM ts_snapshot GROUP BY path;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            var total: Int64 = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let b = sqlite3_column_int64(stmt, 1)
                if b > 0 { total &+= b }
                else { total &+= fileSizeForSnapshotPath(path) }
            }
            return total
        }
    }

    func sumSnapshotBytesSince(ms cutoffMs: Int64) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            let sql = "SELECT path, MAX(COALESCE(bytes, 0)) AS b FROM ts_snapshot WHERE started_at_ms >= ? GROUP BY path;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            var total: Int64 = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let b = sqlite3_column_int64(stmt, 1)
                if b > 0 { total &+= b }
                else { total &+= fileSizeForSnapshotPath(path) }
            }
            return total
        }
    }

    private func fileSizeForSnapshotPath(_ path: String) -> Int64 {
        var size: Int64 = 0
        StoragePaths.withSecurityScope {
            let u = URL(fileURLWithPath: path)
            if let vals = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
                size = Int64(vals.fileSize ?? 0)
            } else if u.pathExtension.lowercased() == "tse" {
                let mov = u.deletingPathExtension().appendingPathExtension("mov")
                if let vals2 = try? mov.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals2.isRegularFile == true {
                    size = Int64(vals2.fileSize ?? 0)
                }
            }
        }
        return size
    }

    func avgSnapshotBytesAll() throws -> Int64 { try avgSnapshotBytes() }

    func avgSnapshotBytesSince(ms cutoffMs: Int64) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT AVG(bytes) FROM ts_snapshot WHERE started_at_ms >= ? AND bytes IS NOT NULL;", -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_int64(stmt, 0) }
            return 0
        }
    }

}
