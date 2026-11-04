import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
  /// Current-version ledgers of days inside `[fromMs, toMs)`, by day start. A row that can't be read is
  /// left out, so it gets rebuilt.
  static func activityLedgers(fromMs: Int64, toMs: Int64, db: OpaquePointer) -> [Int64: ActivityLedger] {
    let sql = "SELECT day_start_ms, json FROM ts_day_ledger WHERE day_start_ms >= ? AND day_end_ms <= ? AND version = ?;"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
    sqlite3_bind_int64(stmt, 1, fromMs)
    sqlite3_bind_int64(stmt, 2, toMs)
    sqlite3_bind_int64(stmt, 3, Int64(ActivityLedger.version))
    let decoder = JSONDecoder()
    var ledgers: [Int64: ActivityLedger] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let text = sqlite3_column_text(stmt, 1),
            let ledger = try? decoder.decode(ActivityLedger.self, from: Data(String(cString: text).utf8)) else { continue }
      ledgers[sqlite3_column_int64(stmt, 0)] = ledger
    }
    return ledgers
  }

  /// Stores nothing and returns false if captures changed since `expectedInvalidations` was read.
  static func storeActivityLedger(_ ledger: ActivityLedger, computedAtMs: Int64, expectedInvalidations: Int64, db: OpaquePointer) throws -> Bool {
    guard summaryInvalidationCount(db: db) == expectedInvalidations else { return false }
    let json = String(decoding: try JSONEncoder().encode(ledger), as: UTF8.self)
    let sql = "INSERT OR REPLACE INTO ts_day_ledger(day_start_ms, day_end_ms, version, json, computed_at_ms) VALUES(?, ?, ?, ?, ?);"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 950) }
    sqlite3_bind_int64(stmt, 1, ledger.startMs)
    sqlite3_bind_int64(stmt, 2, ledger.endMs)
    sqlite3_bind_int64(stmt, 3, Int64(ActivityLedger.version))
    sqlite3_bind_text(stmt, 4, json, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 5, computedAtMs)
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 951) }
    return true
  }
}
