import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
  func timelapseRecordingIntervals(fromMs: Int64, toMs: Int64) throws -> [ClosedRange<Int64>] {
    try onReadQueueSync { db in
      try Self.timelapseRecordingIntervals(fromMs: fromMs, toMs: toMs, db: db)
    }
  }

  static func timelapseRecordingIntervals(fromMs: Int64, toMs: Int64, db: OpaquePointer) throws -> [ClosedRange<Int64>] {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = "SELECT start_s, end_s FROM ts_usage_session WHERE start_s <= ? AND (end_s IS NULL OR end_s >= ?) ORDER BY start_s;"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TimelapseError.encoding }
    sqlite3_bind_double(stmt, 1, Double(toMs) / 1000)
    sqlite3_bind_double(stmt, 2, Double(fromMs) / 1000)
    var intervals: [ClosedRange<Int64>] = []
    var result = sqlite3_step(stmt)
    while result == SQLITE_ROW {
      let start = max(fromMs, Int64((sqlite3_column_double(stmt, 0) * 1000).rounded()))
      let end = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? toMs
        : min(toMs, Int64((sqlite3_column_double(stmt, 1) * 1000).rounded()))
      if end >= start {
        if let last = intervals.last, last.upperBound >= start {
          intervals[intervals.count - 1] = last.lowerBound...max(last.upperBound, end)
        } else {
          intervals.append(start...end)
        }
      }
      result = sqlite3_step(stmt)
    }
    guard result == SQLITE_DONE else { throw TimelapseError.encoding }
    return intervals
  }

  func timelapseFrames(fromMs: Int64, toMs: Int64, throughID: Int64, after: TimelapseFrame?, limit: Int = 256) throws -> [TimelapseFrame] {
    try onReadQueueSync { db in
      try Self.timelapseFrames(fromMs: fromMs, toMs: toMs, throughID: throughID, after: after, limit: limit, db: db)
    }
  }

  static func timelapseFrames(fromMs: Int64, toMs: Int64, throughID: Int64, after: TimelapseFrame?, limit: Int, db: OpaquePointer) throws -> [TimelapseFrame] {
    let sql = """
    SELECT id, started_at_ms, path, COALESCE(format, ''), thumb_path FROM ts_snapshot
    WHERE capture_kind = 'screen' AND started_at_ms >= ? AND started_at_ms <= ? AND id <= ?
      AND (started_at_ms != ? OR id > ?)
    ORDER BY started_at_ms, id LIMIT ?;
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TimelapseError.encoding }
    sqlite3_bind_int64(stmt, 1, max(fromMs, after?.timeMs ?? fromMs))
    sqlite3_bind_int64(stmt, 2, toMs)
    sqlite3_bind_int64(stmt, 3, throughID)
    sqlite3_bind_int64(stmt, 4, after?.timeMs ?? Int64.min)
    sqlite3_bind_int64(stmt, 5, after?.id ?? 0)
    sqlite3_bind_int(stmt, 6, Int32(clamping: max(1, limit)))
    var rows: [TimelapseFrame] = []
    var result = sqlite3_step(stmt)
    while result == SQLITE_ROW {
      guard let path = sqlite3_column_text(stmt, 2), let format = sqlite3_column_text(stmt, 3) else { throw TimelapseError.encoding }
      rows.append(TimelapseFrame(id: sqlite3_column_int64(stmt, 0), timeMs: sqlite3_column_int64(stmt, 1),
                                 path: String(cString: path), format: String(cString: format),
                                 thumbPath: sqlite3_column_text(stmt, 4).map { String(cString: $0) }))
      result = sqlite3_step(stmt)
    }
    guard result == SQLITE_DONE else { throw TimelapseError.encoding }
    return rows
  }

  func timelapseSummary(fromMs: Int64, toMs: Int64) throws -> (maxID: Int64, count: Int, width: Int, height: Int) {
    try onReadQueueSync { db in
      try Self.timelapseSummary(fromMs: fromMs, toMs: toMs, db: db)
    }
  }

  static func timelapseSummary(fromMs: Int64, toMs: Int64, db: OpaquePointer) throws -> (maxID: Int64, count: Int, width: Int, height: Int) {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = """
    SELECT COALESCE(MAX(id), 0), COUNT(*), COALESCE(MAX(width), 0), COALESCE(MAX(height), 0)
    FROM ts_snapshot WHERE capture_kind = 'screen' AND started_at_ms >= ? AND started_at_ms <= ?;
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TimelapseError.encoding }
    sqlite3_bind_int64(stmt, 1, fromMs)
    sqlite3_bind_int64(stmt, 2, toMs)
    guard sqlite3_step(stmt) == SQLITE_ROW else { throw TimelapseError.encoding }
    return (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int64(stmt, 1)),
            Int(sqlite3_column_int(stmt, 2)), Int(sqlite3_column_int(stmt, 3)))
  }
}
