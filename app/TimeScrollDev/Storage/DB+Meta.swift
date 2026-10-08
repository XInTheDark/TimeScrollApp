import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Small integer key/value store inside the database for migration state that must
/// travel with the data (and stay encrypted with it).
extension DB {
    static func createMetaTableIfNeeded(db: OpaquePointer) {
        _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ts_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);", nil, nil, nil)
    }

    static func metaInt(_ key: String, db: OpaquePointer) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM ts_meta WHERE key=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    static func setMetaInt(_ key: String, _ value: Int64, db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ts_meta(key, value) VALUES(?, ?);", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.DB", code: 600, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, value)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "TS.DB", code: 601, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}
