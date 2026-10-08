import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    private static let sqliteMaintenanceKey = "maintenance.lastSQLiteOptimizeAtMs"
    private static let sqliteMaintenanceIntervalMs: Int64 = 6 * 60 * 60 * 1000
    private static let ftsMergePages = 500

    func runAutomaticMaintenance(force: Bool = false, afterLargeDelete: Bool = false) {
        let ranAtMs = try? onQueueSync { () -> Int64? in
            try openIfNeeded()
            guard let db = db else { return nil }

            let defaults = UserDefaults.standard
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let lastRun = Int64(defaults.object(forKey: Self.sqliteMaintenanceKey) != nil
                ? defaults.double(forKey: Self.sqliteMaintenanceKey)
                : 0)
            if !force, nowMs - lastRun < Self.sqliteMaintenanceIntervalMs {
                return nil
            }

            _ = sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            if force {
                // Explicit user request: full merge of all FTS b-trees.
                _ = sqlite3_exec(db, "INSERT INTO ts_text_index(ts_text_index) VALUES('optimize');", nil, nil, nil)
            } else {
                // Scheduled runs do bounded incremental merges so the shared DB queue is
                // never held for a full index rewrite.
                _ = sqlite3_exec(db, "INSERT INTO ts_text_index(ts_text_index, rank) VALUES('merge', \(Self.ftsMergePages));", nil, nil, nil)
            }
            if afterLargeDelete || force {
                _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
            }
            return nowMs
        }
        // Record outside the DB queue: defaults writes post notifications synchronously,
        // and observers must never be able to block the DB queue.
        if let ranAtMs = ranAtMs ?? nil {
            UserDefaults.standard.set(Double(ranAtMs), forKey: Self.sqliteMaintenanceKey)
        }
    }
}
