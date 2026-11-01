import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// What a day's sessions were computed from. When the captures in the day's window change
/// (new captures, text arriving after OCR, sketches backfilled, deletions), so does this.
struct SessionDayFingerprint: Equatable {
  let snapshotCount: Int
  let maxSnapshotId: Int64
  let textCount: Int
  let sketchedCount: Int

  /// Every capture with text has a sketch, so recomputing would not change the result.
  var isComplete: Bool { sketchedCount >= textCount }
}

/// A day's stored sessions and how they were computed.
struct SessionDayRecord: Equatable {
  let dayStartMs: Int64
  let windowStartMs: Int64
  let windowEndMs: Int64
  /// Algorithm version and sensitivity; a mismatch means the day must be recomputed.
  let params: String
  let fingerprint: SessionDayFingerprint
  let computedAtMs: Int64
}

/// Computed sessions are stored per day so search and the timeline do not recompute them.
extension DB {
  static func createActivitySessionTablesIfNeeded(db: OpaquePointer) {
    let sql = """
    CREATE TABLE IF NOT EXISTS ts_session_day (
        day_start_ms INTEGER PRIMARY KEY,
        window_start_ms INTEGER NOT NULL,
        window_end_ms INTEGER NOT NULL,
        params TEXT NOT NULL,
        snapshot_count INTEGER NOT NULL,
        max_snapshot_id INTEGER NOT NULL,
        text_count INTEGER NOT NULL,
        sketched_count INTEGER NOT NULL,
        computed_at_ms INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ts_activity_session (
        id INTEGER NOT NULL,
        day_start_ms INTEGER NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        snapshot_count INTEGER NOT NULL,
        apps TEXT NOT NULL,
        keywords TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_ts_activity_session_day ON ts_activity_session(day_start_ms);
    """
    _ = sqlite3_exec(db, sql, nil, nil, nil)
  }

  /// SQL dropping stored days whose window includes `timeMsSQL` (an expression), so they are
  /// recomputed; appended to the statements that delete captures.
  static func sessionDayInvalidationSQL(windowContaining timeMsSQL: String) -> String {
    "DELETE FROM ts_session_day WHERE window_start_ms <= \(timeMsSQL) AND window_end_ms > \(timeMsSQL);"
  }

  static let allSessionDaysDeletionSQL = "DELETE FROM ts_session_day; DELETE FROM ts_activity_session;"

  func sessionDayFingerprint(fromMs: Int64, toMs: Int64) throws -> SessionDayFingerprint {
    try onReadQueueSync { db in try Self.sessionDayFingerprint(fromMs: fromMs, toMs: toMs, db: db) }
  }

  static func sessionDayFingerprint(fromMs: Int64, toMs: Int64, db: OpaquePointer) throws -> SessionDayFingerprint {
    let sql = """
    SELECT COUNT(*), COALESCE(MAX(s.id), 0), COUNT(COALESCE(s.text_store_id, r.text_store_id)), COUNT(k.text_store_id)
    FROM ts_snapshot s
    LEFT JOIN ts_snapshot r ON s.text_store_id IS NULL AND r.id = s.text_ref_id
    LEFT JOIN ts_session_sketch k ON k.text_store_id = COALESCE(s.text_store_id, r.text_store_id)
    WHERE s.capture_kind = 'screen' AND s.started_at_ms >= ? AND s.started_at_ms < ?;
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 910, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    sqlite3_bind_int64(stmt, 1, fromMs)
    sqlite3_bind_int64(stmt, 2, toMs)
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw NSError(domain: "TS.DB", code: 911) }
    return SessionDayFingerprint(snapshotCount: Int(sqlite3_column_int64(stmt, 0)),
                                 maxSnapshotId: sqlite3_column_int64(stmt, 1),
                                 textCount: Int(sqlite3_column_int64(stmt, 2)),
                                 sketchedCount: Int(sqlite3_column_int64(stmt, 3)))
  }

  func sessionDayRecord(dayStartMs: Int64) throws -> SessionDayRecord? {
    try onReadQueueSync { db in Self.sessionDayRecord(dayStartMs: dayStartMs, db: db) }
  }

  static func sessionDayRecord(dayStartMs: Int64, db: OpaquePointer) -> SessionDayRecord? {
    let sql = """
    SELECT window_start_ms, window_end_ms, params, snapshot_count, max_snapshot_id, text_count, sketched_count, computed_at_ms
    FROM ts_session_day WHERE day_start_ms = ? LIMIT 1;
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_int64(stmt, 1, dayStartMs)
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return SessionDayRecord(dayStartMs: dayStartMs,
                            windowStartMs: sqlite3_column_int64(stmt, 0),
                            windowEndMs: sqlite3_column_int64(stmt, 1),
                            params: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                            fingerprint: SessionDayFingerprint(snapshotCount: Int(sqlite3_column_int64(stmt, 3)),
                                                               maxSnapshotId: sqlite3_column_int64(stmt, 4),
                                                               textCount: Int(sqlite3_column_int64(stmt, 5)),
                                                               sketchedCount: Int(sqlite3_column_int64(stmt, 6))),
                            computedAtMs: sqlite3_column_int64(stmt, 7))
  }

  func activitySessions(dayStartMs: Int64) throws -> [ActivitySession] {
    try onReadQueueSync { db in Self.activitySessions(dayStartMs: dayStartMs, db: db) }
  }

  static func activitySessions(dayStartMs: Int64, db: OpaquePointer) -> [ActivitySession] {
    let sql = "SELECT id, start_ms, end_ms, snapshot_count, apps, keywords FROM ts_activity_session WHERE day_start_ms = ? ORDER BY start_ms ASC;"
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_int64(stmt, 1, dayStartMs)
    var sessions: [ActivitySession] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let apps = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "[]"
      let keywords = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "[]"
      sessions.append(ActivitySession(id: sqlite3_column_int64(stmt, 0),
                                      startMs: sqlite3_column_int64(stmt, 1),
                                      endMs: sqlite3_column_int64(stmt, 2),
                                      snapshotCount: Int(sqlite3_column_int64(stmt, 3)),
                                      apps: ActivitySessionColumns.decodeApps(apps),
                                      keywords: ActivitySessionColumns.decodeKeywords(keywords)))
    }
    return sessions
  }

  /// Replaces a day's sessions and its record in one transaction.
  func replaceActivitySessions(_ sessions: [ActivitySession], record: SessionDayRecord) throws {
    try withWriteSavepoint {
      guard let db else { return }
      try Self.replaceActivitySessions(sessions, record: record, db: db)
    }
  }

  /// Callers wrap this in a transaction.
  static func replaceActivitySessions(_ sessions: [ActivitySession], record: SessionDayRecord, db: OpaquePointer) throws {
    var delete: OpaquePointer?
    defer { sqlite3_finalize(delete) }
    guard sqlite3_prepare_v2(db, "DELETE FROM ts_activity_session WHERE day_start_ms = ?;", -1, &delete, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 920)
    }
    sqlite3_bind_int64(delete, 1, record.dayStartMs)
    guard sqlite3_step(delete) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 921) }

    var insert: OpaquePointer?
    defer { sqlite3_finalize(insert) }
    let insertSQL = "INSERT INTO ts_activity_session(id, day_start_ms, start_ms, end_ms, snapshot_count, apps, keywords) VALUES(?, ?, ?, ?, ?, ?, ?);"
    guard sqlite3_prepare_v2(db, insertSQL, -1, &insert, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 922) }
    for session in sessions {
      sqlite3_reset(insert)
      sqlite3_bind_int64(insert, 1, session.id)
      sqlite3_bind_int64(insert, 2, record.dayStartMs)
      sqlite3_bind_int64(insert, 3, session.startMs)
      sqlite3_bind_int64(insert, 4, session.endMs)
      sqlite3_bind_int64(insert, 5, Int64(session.snapshotCount))
      sqlite3_bind_text(insert, 6, ActivitySessionColumns.encodeApps(session.apps), -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(insert, 7, ActivitySessionColumns.encodeKeywords(session.keywords), -1, SQLITE_TRANSIENT)
      guard sqlite3_step(insert) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 923) }
    }

    var day: OpaquePointer?
    defer { sqlite3_finalize(day) }
    let daySQL = """
    INSERT OR REPLACE INTO ts_session_day(day_start_ms, window_start_ms, window_end_ms, params, snapshot_count, max_snapshot_id, text_count, sketched_count, computed_at_ms)
    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
    """
    guard sqlite3_prepare_v2(db, daySQL, -1, &day, nil) == SQLITE_OK else { throw NSError(domain: "TS.DB", code: 924) }
    sqlite3_bind_int64(day, 1, record.dayStartMs)
    sqlite3_bind_int64(day, 2, record.windowStartMs)
    sqlite3_bind_int64(day, 3, record.windowEndMs)
    sqlite3_bind_text(day, 4, record.params, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(day, 5, Int64(record.fingerprint.snapshotCount))
    sqlite3_bind_int64(day, 6, record.fingerprint.maxSnapshotId)
    sqlite3_bind_int64(day, 7, Int64(record.fingerprint.textCount))
    sqlite3_bind_int64(day, 8, Int64(record.fingerprint.sketchedCount))
    sqlite3_bind_int64(day, 9, record.computedAtMs)
    guard sqlite3_step(day) == SQLITE_DONE else { throw NSError(domain: "TS.DB", code: 925) }
  }
}
