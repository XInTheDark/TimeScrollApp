import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Removing Time Warp records with the captures they belong to. A deletion removes every record
/// that touches the range, whole: deleting 10:20–10:30 also removes a page in front 10:00–11:00.
extension DB {
  /// Deletes the records that touch `[fromMs, toMs)`, in one transaction. `appBundleIds` limits it to those apps' records; empty means all.
  func deleteTimeWarpRecords(fromMs: Int64, toMs: Int64, appBundleIds: [String] = []) throws {
    guard toMs > fromMs else { return }
    try onQueueSync {
      try openIfNeeded()
      guard let db else { throw NSError(domain: "TS.DB", code: 3) }
      try Self.deleteTimeWarpRecords(fromMs: fromMs, toMs: toMs, appBundleIds: appBundleIds, db: db)
      Self.timeWarpValueCache.removeAll()
    }
  }

  /// Retention: records that ended before `cutoffMs` go, and spans crossing it start at it.
  func purgeTimeWarpRecords(olderThan cutoffMs: Int64) throws {
    try onQueueSync {
      try openIfNeeded()
      guard let db else { throw NSError(domain: "TS.DB", code: 3) }
      try Self.purgeTimeWarpRecords(olderThan: cutoffMs, db: db)
      Self.timeWarpValueCache.removeAll()
    }
  }

  /// Removes every Time Warp record.
  func deleteAllTimeWarpRecords() throws {
    try onQueueSync {
      try openIfNeeded()
      guard let db else { throw NSError(domain: "TS.DB", code: 3) }
      try Self.execTimeWarp(db, "BEGIN IMMEDIATE; DELETE FROM ts_tw_span; DELETE FROM ts_tw_value; COMMIT;")
      Self.timeWarpValueCache.removeAll()
    }
  }

  static func deleteTimeWarpRecords(fromMs: Int64, toMs: Int64, appBundleIds: [String] = [], db: OpaquePointer) throws {
    guard toMs > fromMs else { return }
    let touching = timeWarpTouchingSQL(fromMs: fromMs, toMs: toMs) + timeWarpAppFilterSQL(appBundleIds)
    try execTimeWarp(db, """
    BEGIN IMMEDIATE;
    \(timeWarpGoneValuesSQL(spansWhere: touching))
    DELETE FROM ts_tw_span WHERE \(touching);
    \(timeWarpUnusedValueDeletionSQL)
    COMMIT;
    """)
  }

  static func purgeTimeWarpRecords(olderThan cutoffMs: Int64, db: OpaquePointer) throws {
    let expired = "start_ms < \(cutoffMs) AND end_ms < \(cutoffMs) AND is_open = 0"
    try execTimeWarp(db, """
    BEGIN IMMEDIATE;
    \(timeWarpGoneValuesSQL(spansWhere: expired))
    DELETE FROM ts_tw_span WHERE \(expired);
    \(timeWarpUnusedValueDeletionSQL)
    COMMIT;
    """)
  }

  /// Records that overlap `[fromMs, toMs)`, including one still being recorded that began before
  /// it ends. Spans never outlast the maximum, so the start index finds them all.
  static func timeWarpTouchingSQL(fromMs: Int64, toMs: Int64) -> String {
    "start_ms >= \(fromMs - timeWarpMaxSpanMs) AND start_ms < \(toMs) AND (end_ms > \(fromMs) OR start_ms >= \(fromMs) OR is_open = 1)"
  }

  /// Notes the strings used by the spans about to be deleted; only these can become unused.
  static func timeWarpGoneValuesSQL(spansWhere condition: String) -> String {
    """
    CREATE TEMP TABLE IF NOT EXISTS ts_tw_gone (id INTEGER PRIMARY KEY);
    DELETE FROM ts_tw_gone;
    INSERT OR IGNORE INTO ts_tw_gone SELECT value_id FROM ts_tw_span WHERE \(condition);
    INSERT OR IGNORE INTO ts_tw_gone SELECT title_id FROM ts_tw_span WHERE title_id IS NOT NULL AND \(condition);
    INSERT OR IGNORE INTO ts_tw_gone SELECT app_id FROM ts_tw_span WHERE app_id IS NOT NULL AND \(condition);
    """
  }

  /// Deletes the noted strings no record uses any more. Values and titles are found through their
  /// indexes; an app is almost always still in use, so its scan stops at the first match.
  static let timeWarpUnusedValueDeletionSQL = """
  DELETE FROM ts_tw_value WHERE id IN (
    SELECT g.id FROM ts_tw_gone g JOIN ts_tw_value v ON v.id = g.id
    WHERE NOT EXISTS (SELECT 1 FROM ts_tw_span WHERE value_id = g.id)
      AND (v.domain != 'title' OR NOT EXISTS (SELECT 1 FROM ts_tw_span WHERE title_id = g.id))
      AND (v.domain != 'app' OR NOT EXISTS (SELECT 1 FROM ts_tw_span WHERE app_id = g.id)));
  DELETE FROM ts_tw_gone;
  """

  private static func timeWarpAppFilterSQL(_ appBundleIds: [String]) -> String {
    guard !appBundleIds.isEmpty else { return "" }
    let quoted = appBundleIds.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
    return " AND app_id IN (SELECT id FROM ts_tw_value WHERE domain = 'app' AND value IN (\(quoted)))"
  }

  private static func execTimeWarp(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      throw NSError(domain: "TS.DB", code: 90, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}
