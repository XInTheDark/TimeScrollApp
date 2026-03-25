import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    private static let sqliteMaintenanceKey = "maintenance.lastSQLiteOptimizeAtMs"
    private static let sqliteMaintenanceIntervalMs: Int64 = 6 * 60 * 60 * 1000

    func runAutomaticMaintenance(force: Bool = false, afterLargeDelete: Bool = false) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }

            let defaults = UserDefaults.standard
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let lastRun = Int64(defaults.object(forKey: Self.sqliteMaintenanceKey) != nil
                ? defaults.double(forKey: Self.sqliteMaintenanceKey)
                : 0)
            if !force, nowMs - lastRun < Self.sqliteMaintenanceIntervalMs {
                return
            }

            _ = sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            _ = sqlite3_exec(db, "INSERT INTO ts_text(ts_text) VALUES('optimize');", nil, nil, nil)
            _ = sqlite3_exec(db, "INSERT INTO ts_text_chunk(ts_text_chunk) VALUES('optimize');", nil, nil, nil)
            if afterLargeDelete || force {
                _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
            }
            defaults.set(Double(nowMs), forKey: Self.sqliteMaintenanceKey)
        }
    }
}
