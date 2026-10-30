import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// One stored capture reduced to what day-activity statistics need.
struct CaptureInterval: Equatable {
  let startMs: Int64
  /// Known end of the capture (audio); nil for point-in-time screen snapshots.
  let endMs: Int64?
  let isAudio: Bool
}

extension DB {
  /// Captures that started in `[fromMs, toMs)`, oldest first.
  func captureIntervals(fromMs: Int64, toMs: Int64) throws -> [CaptureInterval] {
    try onReadQueueSync { db in
      let sql = """
      SELECT s.started_at_ms, COALESCE(s.ended_at_ms, s.started_at_ms + a.duration_ms), s.capture_kind
      FROM ts_snapshot s
      LEFT JOIN ts_audio_asset a ON a.id = s.audio_asset_id
      WHERE s.started_at_ms >= ? AND s.started_at_ms < ?
      ORDER BY s.started_at_ms ASC;
      """
      var stmt: OpaquePointer?
      defer { sqlite3_finalize(stmt) }
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
      sqlite3_bind_int64(stmt, 1, fromMs)
      sqlite3_bind_int64(stmt, 2, toMs)
      var rows: [CaptureInterval] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        let endMs = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1)
        let kind = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        rows.append(CaptureInterval(startMs: sqlite3_column_int64(stmt, 0),
                                    endMs: endMs,
                                    isAudio: kind == CaptureKind.audio.rawValue))
      }
      return rows
    }
  }

  /// The earliest capture that started in `[fromMs, toMs)`.
  func firstSnapshot(fromMs: Int64, toMs: Int64) throws -> (id: Int64, startedAtMs: Int64)? {
    try onReadQueueSync { db in
      let sql = "SELECT id, started_at_ms FROM ts_snapshot WHERE started_at_ms >= ? AND started_at_ms < ? ORDER BY started_at_ms ASC LIMIT 1;"
      var stmt: OpaquePointer?
      defer { sqlite3_finalize(stmt) }
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
      sqlite3_bind_int64(stmt, 1, fromMs)
      sqlite3_bind_int64(stmt, 2, toMs)
      guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
      return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
    }
  }
}
