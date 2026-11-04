import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
  static func rangeSummary(startMs: Int64, endMs: Int64, db: OpaquePointer) -> StoredRangeSummary? {
    rangeSummaries(sql: "start_ms = ? AND end_ms = ?", startMs, endMs, db: db).first
  }

  /// Summaries that fall entirely inside `[fromMs, toMs)`, oldest first.
  static func rangeSummaries(insideFromMs fromMs: Int64, toMs: Int64, db: OpaquePointer) -> [StoredRangeSummary] {
    rangeSummaries(sql: "start_ms >= ? AND end_ms <= ? ORDER BY start_ms ASC, end_ms ASC", fromMs, toMs, db: db)
  }

  private static func rangeSummaries(sql condition: String, _ first: Int64, _ second: Int64, db: OpaquePointer) -> [StoredRangeSummary] {
    let sql = "SELECT start_ms, end_ms, model, prompt_version, text, created_at_ms FROM ts_range_summary WHERE \(condition);"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_int64(stmt, 1, first)
    sqlite3_bind_int64(stmt, 2, second)
    var summaries: [StoredRangeSummary] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      summaries.append(StoredRangeSummary(startMs: sqlite3_column_int64(stmt, 0),
                                          endMs: sqlite3_column_int64(stmt, 1),
                                          model: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                                          promptVersion: Int(sqlite3_column_int64(stmt, 3)),
                                          text: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                                          createdAtMs: sqlite3_column_int64(stmt, 5)))
    }
    return summaries
  }

  /// Stores nothing and returns false if captures changed since `expectedInvalidations` was read,
  /// so a summary can't describe something deleted while the model was running.
  static func storeRangeSummary(_ summary: StoredRangeSummary, expectedInvalidations: Int64, db: OpaquePointer) throws -> Bool {
    guard summaryInvalidationCount(db: db) == expectedInvalidations else { return false }
    let sql = "INSERT OR REPLACE INTO ts_range_summary(start_ms, end_ms, model, prompt_version, text, created_at_ms) VALUES(?, ?, ?, ?, ?, ?);"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 940) }
    sqlite3_bind_int64(stmt, 1, summary.startMs)
    sqlite3_bind_int64(stmt, 2, summary.endMs)
    sqlite3_bind_text(stmt, 3, summary.model, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 4, Int64(summary.promptVersion))
    sqlite3_bind_text(stmt, 5, summary.text, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 6, summary.createdAtMs)
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 941) }
    return true
  }
}
