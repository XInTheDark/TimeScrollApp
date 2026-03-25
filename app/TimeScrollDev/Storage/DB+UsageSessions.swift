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

    func totalUsageSeconds(now: TimeInterval) throws -> TimeInterval {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            // Fetch all sessions up to now and compute the union of intervals to avoid double counting
            let sql = "SELECT start_s, COALESCE(end_s, ?) AS end_s FROM ts_usage_session WHERE start_s <= ? ORDER BY start_s ASC;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_double(stmt, 2, now)

            var mergedStart: Double? = nil
            var mergedEnd: Double = 0
            var total: Double = 0

            while sqlite3_step(stmt) == SQLITE_ROW {
                let s = sqlite3_column_double(stmt, 0)
                let eRaw = sqlite3_column_double(stmt, 1)
                // Clamp any inverted rows defensively
                let e = max(eRaw, s)
                if mergedStart == nil {
                    mergedStart = s; mergedEnd = e
                    continue
                }
                if s > mergedEnd { // disjoint
                    total += max(0, mergedEnd - (mergedStart ?? mergedEnd))
                    mergedStart = s; mergedEnd = e
                } else { // overlap or touch
                    if e > mergedEnd { mergedEnd = e }
                }
            }
            if let ms = mergedStart {
                total += max(0, mergedEnd - ms)
            }
            return total
        }
    }

    func usageSecondsSince(cutoff: TimeInterval, now: TimeInterval) throws -> TimeInterval {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            let lo = min(cutoff, now)
            let hi = max(cutoff, now)
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            // Fetch sessions overlapping [cutoff, now] and compute the union of clamped intervals
            let sql = "SELECT start_s, end_s FROM ts_usage_session WHERE start_s <= ? AND COALESCE(end_s, ?) >= ? ORDER BY start_s ASC;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_double(stmt, 1, hi)
            sqlite3_bind_double(stmt, 2, hi)
            sqlite3_bind_double(stmt, 3, lo)

            var mergedStart: Double? = nil
            var mergedEnd: Double = 0
            var total: Double = 0

            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawS = sqlite3_column_double(stmt, 0)
                let rawE = (sqlite3_column_type(stmt, 1) != SQLITE_NULL) ? sqlite3_column_double(stmt, 1) : hi
                // Clamp to [lo, hi] and ensure non-negative interval
                let s = max(lo, min(rawS, hi))
                let e = max(s, min(rawE, hi))

                if mergedStart == nil {
                    mergedStart = s; mergedEnd = e
                    continue
                }
                if s > mergedEnd { // disjoint
                    total += max(0, mergedEnd - (mergedStart ?? mergedEnd))
                    mergedStart = s; mergedEnd = e
                } else { // overlap or touch
                    if e > mergedEnd { mergedEnd = e }
                }
            }
            if let ms = mergedStart { total += max(0, mergedEnd - ms) }
            return total
        }
    }

    func finalizeStaleOpenUsageSessions(maxOpenSeconds: TimeInterval, now: TimeInterval) {
        _ = try? onQueueSync {
            try openIfNeeded(); guard let db = db else { return }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT id, start_s FROM ts_usage_session WHERE end_s IS NULL;", -1, &stmt, nil) != SQLITE_OK { return }
            var stale: [(Int64, Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let start = sqlite3_column_double(stmt, 1)
                if now - start > maxOpenSeconds {
                    stale.append((id, start))
                }
            }
            sqlite3_finalize(stmt); stmt = nil
            if stale.isEmpty { return }
            for (id, start) in stale {
                var upd: OpaquePointer?; defer { sqlite3_finalize(upd) }
                if sqlite3_prepare_v2(db, "UPDATE ts_usage_session SET end_s=? WHERE id=? AND end_s IS NULL;", -1, &upd, nil) == SQLITE_OK {
                    let clampEnd = start + maxOpenSeconds
                    sqlite3_bind_double(upd, 1, clampEnd)
                    sqlite3_bind_int64(upd, 2, id)
                    _ = sqlite3_step(upd)
                }
            }
        }
    }

    /// Close all open usage sessions using the last snapshot timestamp as the end time.
    /// This provides accurate bounds: the session ran at least until the last captured snapshot.
    /// If no snapshots exist for a session, end_s = start_s (0 duration, conservative).
    func closeAllOpenUsageSessions() {
        _ = try? onQueueSync {
            try openIfNeeded(); guard let db = db else { return }
            // Use a single UPDATE with a correlated subquery for efficiency:
            // Set end_s to the latest snapshot time (in seconds) that occurred after session start,
            // or fall back to start_s if no snapshots exist.
            let sql = """
            UPDATE ts_usage_session
            SET end_s = COALESCE(
                (SELECT MAX(started_at_ms) / 1000.0
                 FROM ts_snapshot
                 WHERE started_at_ms >= ts_usage_session.start_s * 1000),
                start_s
            )
            WHERE end_s IS NULL;
            """
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
            _ = sqlite3_step(stmt)
        }
    }

}
