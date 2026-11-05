import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    // MARK: - Usage sessions
    func beginUsageSession(start: TimeInterval) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { throw NSError(domain: "TS.DB", code: 800) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT INTO ts_usage_session(start_s) VALUES(?);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw NSError(domain: "TS.DB", code: 801) }
            sqlite3_bind_double(stmt, 1, start)
            if sqlite3_step(stmt) != SQLITE_DONE { throw NSError(domain: "TS.DB", code: 802) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func endUsageSession(id: Int64, end: TimeInterval) throws {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "UPDATE ts_usage_session SET end_s=? WHERE id=? AND end_s IS NULL;", -1, &stmt, nil) != SQLITE_OK { return }
            sqlite3_bind_double(stmt, 1, end)
            sqlite3_bind_int64(stmt, 2, id)
            _ = sqlite3_step(stmt)
        }
    }

    /// Time covered by usage sessions between `from` (or the beginning of time when nil) and `to`.
    func usageSeconds(from: TimeInterval?, to: TimeInterval) throws -> TimeInterval {
        try onReadQueueSync { db in
            try Self.usageSeconds(from: from, to: to, db: db)
        }
    }

    /// Overlapping sessions are merged so that no moment counts twice. An open session runs until `to`.
    static func usageSeconds(from: TimeInterval?, to: TimeInterval, db: OpaquePointer) throws -> TimeInterval {
        let lo = from ?? -Double.greatestFiniteMagnitude
        guard lo <= to else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT start_s, COALESCE(end_s, ?1) FROM ts_usage_session WHERE start_s <= ?1 AND COALESCE(end_s, ?1) >= ?2 ORDER BY start_s ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 803) }
        sqlite3_bind_double(stmt, 1, to)
        sqlite3_bind_double(stmt, 2, lo)

        var total: Double = 0
        var coveredThrough = lo
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            let start = max(coveredThrough, sqlite3_column_double(stmt, 0))
            let end = min(to, sqlite3_column_double(stmt, 1))
            if end > start {
                total += end - start
                coveredThrough = end
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 804) }
        return total
    }

    /// Closes sessions a previous run left open. Returns false if the database is unavailable
    /// (for example a locked vault), in which case they are still open.
    @discardableResult
    func closeOrphanedUsageSessions(startedBefore launchTime: TimeInterval) -> Bool {
        let closed: Bool? = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return false }
            return Self.closeOrphanedUsageSessions(startedBefore: launchTime, db: db)
        }
        return closed ?? false
    }

    /// An orphan ran at least until its last snapshot, which is all that can be known about it. Snapshots
    /// from the next session or from this run, which may already exist, say nothing about when it ended.
    static func closeOrphanedUsageSessions(startedBefore launchTime: TimeInterval, db: OpaquePointer) -> Bool {
        let sql = """
        UPDATE ts_usage_session
        SET end_s = COALESCE(
            (SELECT MAX(started_at_ms) / 1000.0
             FROM ts_snapshot
             WHERE started_at_ms >= ts_usage_session.start_s * 1000
               AND started_at_ms < COALESCE(
                 (SELECT MIN(next.start_s) FROM ts_usage_session AS next
                  WHERE next.start_s > ts_usage_session.start_s AND next.start_s < ?1),
                 ?1) * 1000),
            start_s
        )
        WHERE end_s IS NULL AND start_s < ?1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_double(stmt, 1, launchTime)
        return sqlite3_step(stmt) == SQLITE_DONE
    }
}
