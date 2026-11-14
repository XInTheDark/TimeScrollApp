import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Warp points for the timeline's markers, on the read connection. A partial index holds only
/// Warp points, so this reads nothing else however many spans the range has.
extension DB {
  /// Most markers one range returns.
  static let timeWarpPointLimit = 5_000

  /// Warp points in `[fromMs, toMs)`, oldest first.
  func timeWarpPoints(fromMs: Int64, toMs: Int64) throws -> [TimeWarpPointNote] {
    try onReadQueueSync { db in Self.timeWarpPoints(fromMs: fromMs, toMs: toMs, db: db) }
  }

  static func timeWarpPoints(fromMs: Int64, toMs: Int64, db: OpaquePointer) -> [TimeWarpPointNote] {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = """
    SELECT s.start_ms, v.value, a.value
    FROM ts_tw_span s
    JOIN ts_tw_value v ON v.id = s.value_id
    LEFT JOIN ts_tw_value a ON a.id = s.app_id
    WHERE s.kind = 'warpPoint' AND s.start_ms >= ? AND s.start_ms < ?
    ORDER BY s.start_ms
    LIMIT \(timeWarpPointLimit);
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_int64(stmt, 1, fromMs)
    sqlite3_bind_int64(stmt, 2, toMs)
    var points: [TimeWarpPointNote] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      points.append(TimeWarpPointNote(timeMs: sqlite3_column_int64(stmt, 0),
                                      note: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                                      appBundleId: sqlite3_column_text(stmt, 2).map { String(cString: $0) }))
    }
    return points
  }
}
