import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// App time rollups: reading captures and reading and replacing stored days.
extension DB {
  /// Screen captures that started in `[fromMs, toMs)`, oldest first, and the time of the next one.
  static func appTimeCaptures(fromMs: Int64, toMs: Int64, db: OpaquePointer) throws -> (captures: [AppTimeCapture], nextCaptureMs: Int64?) {
    let sql = """
    SELECT started_at_ms, COALESCE(app_bundle_id, app_name, '') FROM ts_snapshot
    WHERE capture_kind = 'screen' AND started_at_ms >= ? AND started_at_ms < ?
    ORDER BY started_at_ms ASC;
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 930, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    sqlite3_bind_int64(stmt, 1, fromMs)
    sqlite3_bind_int64(stmt, 2, toMs)
    var captures: [AppTimeCapture] = []
    // Consecutive captures are usually the same app; reuse its string rather than allocate one per row.
    var lastBytes: [UInt8] = []
    var lastApp = ""
    while sqlite3_step(stmt) == SQLITE_ROW {
      let count = Int(sqlite3_column_bytes(stmt, 1))
      if let text = sqlite3_column_text(stmt, 1) {
        if count != lastBytes.count || memcmp(text, lastBytes, count) != 0 {
          lastBytes = Array(UnsafeBufferPointer(start: text, count: count))
          lastApp = String(decoding: lastBytes, as: UTF8.self)
        }
      } else {
        lastBytes = []
        lastApp = ""
      }
      captures.append(AppTimeCapture(timeMs: sqlite3_column_int64(stmt, 0), app: lastApp))
    }

    var next: OpaquePointer?
    defer { sqlite3_finalize(next) }
    guard sqlite3_prepare_v2(db, "SELECT MIN(started_at_ms) FROM ts_snapshot WHERE capture_kind = 'screen' AND started_at_ms >= ?;", -1, &next, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 931)
    }
    sqlite3_bind_int64(next, 1, toMs)
    let hasNext = sqlite3_step(next) == SQLITE_ROW && sqlite3_column_type(next, 0) != SQLITE_NULL
    return (captures, hasNext ? sqlite3_column_int64(next, 0) : nil)
  }

  static func appTimeRows(span: AppTimeSpan, fromMs: Int64, toMs: Int64, app: String? = nil, db: OpaquePointer) throws -> [AppTimeRow] {
    let filter = app == nil ? "" : " AND app = ?"
    let sql = "SELECT bucket_ms, app, dwell_ms, snapshot_count FROM ts_app_time WHERE span = ? AND bucket_ms >= ? AND bucket_ms < ?\(filter);"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 932, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    sqlite3_bind_int(stmt, 1, span.rawValue)
    sqlite3_bind_int64(stmt, 2, fromMs)
    sqlite3_bind_int64(stmt, 3, toMs)
    if let app { sqlite3_bind_text(stmt, 4, app, -1, SQLITE_TRANSIENT) }
    var rows: [AppTimeRow] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      rows.append(AppTimeRow(bucketMs: sqlite3_column_int64(stmt, 0),
                             app: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                             dwellMs: sqlite3_column_int64(stmt, 2),
                             snapshotCount: sqlite3_column_int64(stmt, 3)))
    }
    return rows
  }

  /// Starts of the days overlapping `[fromMs, toMs)` that are built with the current version.
  static func builtAppTimeDays(fromMs: Int64, toMs: Int64, db: OpaquePointer) throws -> Set<Int64> {
    let sql = "SELECT day_start_ms FROM ts_app_time_day WHERE day_start_ms < ? AND day_end_ms > ? AND version = ?;"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 933) }
    sqlite3_bind_int64(stmt, 1, toMs)
    sqlite3_bind_int64(stmt, 2, fromMs)
    sqlite3_bind_int(stmt, 3, Int32(AppTimeRollup.version))
    var days = Set<Int64>()
    while sqlite3_step(stmt) == SQLITE_ROW { days.insert(sqlite3_column_int64(stmt, 0)) }
    return days
  }

  /// Replaces a day and any older days it overlaps (from a different time zone). Stores nothing and
  /// returns false if captures changed since `expectedInvalidations` was read. Callers wrap this in
  /// a transaction.
  static func replaceAppTimeDay(_ day: SessionDayPlanner.Day, rollup: AppTimeRollup.Day, computedAtMs: Int64,
                                expectedInvalidations: Int64, db: OpaquePointer) throws -> Bool {
    guard summaryInvalidationCount(db: db) == expectedInvalidations else { return false }
    let deletion = appTimeDayDeletionSQL(where: "day_start_ms < \(day.endMs) AND day_end_ms > \(day.startMs)")
    guard sqlite3_exec(db, deletion, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 934, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    var insert: OpaquePointer?
    defer { sqlite3_finalize(insert) }
    // A bucket can only meet two days where a zone's midnight isn't on a quarter hour.
    let sql = """
    INSERT INTO ts_app_time(span, bucket_ms, app, dwell_ms, snapshot_count) VALUES(?, ?, ?, ?, ?)
    ON CONFLICT(span, bucket_ms, app) DO UPDATE SET dwell_ms = dwell_ms + excluded.dwell_ms, snapshot_count = snapshot_count + excluded.snapshot_count;
    """
    guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 935) }
    func store(_ rows: [AppTimeRow], span: AppTimeSpan) throws {
      for row in rows {
        sqlite3_reset(insert)
        sqlite3_bind_int(insert, 1, span.rawValue)
        sqlite3_bind_int64(insert, 2, row.bucketMs)
        sqlite3_bind_text(insert, 3, row.app, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(insert, 4, row.dwellMs)
        sqlite3_bind_int64(insert, 5, row.snapshotCount)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 936) }
      }
    }
    try store(rollup.quarterHours, span: .quarterHour)
    try store(rollup.day, span: .day)

    var record: OpaquePointer?
    defer { sqlite3_finalize(record) }
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ts_app_time_day(day_start_ms, day_end_ms, version, computed_at_ms) VALUES(?, ?, ?, ?);", -1, &record, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 937)
    }
    sqlite3_bind_int64(record, 1, day.startMs)
    sqlite3_bind_int64(record, 2, day.endMs)
    sqlite3_bind_int(record, 3, Int32(AppTimeRollup.version))
    sqlite3_bind_int64(record, 4, computedAtMs)
    guard sqlite3_step(record) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 938) }
    return true
  }

  /// The app's most recent name, or nil for apps stored under their name alone.
  static func appTimeDisplayName(app: String, db: OpaquePointer) -> String? {
    let sql = "SELECT app_name FROM ts_snapshot WHERE app_bundle_id = ? AND app_name IS NOT NULL ORDER BY started_at_ms DESC LIMIT 1;"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_text(stmt, 1, app, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
  }

  static func earliestScreenCaptureMs(db: OpaquePointer) -> Int64? {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT MIN(started_at_ms) FROM ts_snapshot WHERE capture_kind = 'screen';", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(stmt, 0)
  }
}
