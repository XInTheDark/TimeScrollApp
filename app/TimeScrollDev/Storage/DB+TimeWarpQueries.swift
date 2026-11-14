import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Reads of Time Warp records, on the read connection.
extension DB {
  /// Most rows one range returns; a range this full is trimmed to the earliest rows.
  static let timeWarpRangeRowLimit = 50_000

  /// Records overlapping `[fromMs, toMs)`. Spans are never longer than `timeWarpMaxSpanMs`, so only
  /// starts from that far before the range need checking, which keeps the query on the start index.
  func timeWarpSpans(fromMs: Int64, toMs: Int64) throws -> [TimeWarpSpanRecord] {
    try onReadQueueSync { db in Self.timeWarpSpans(fromMs: fromMs, toMs: toMs, db: db) }
  }

  /// The page or file in front at `timeMs` in `appBundleId`, if one was recorded.
  func timeWarpFrontItem(atMs timeMs: Int64, appBundleId: String) throws -> TimeWarpSpanRecord? {
    try onReadQueueSync { db in
      Self.timeWarpSpans(fromMs: timeMs, toMs: timeMs + 1, db: db)
        .filter { $0.source == .front && $0.kind != .app && $0.appBundleId == appBundleId }
        .max { $0.startMs < $1.startMs }
    }
  }

  /// How many different pages, files, folders, apps and notes a range delete would remove; for the
  /// delete confirmation. Distinct, like the items Time Warp lists, so app switches count once per app.
  static func countTimeWarpSpans(fromMs: Int64, toMs: Int64, appBundleIds: [String] = [], db: OpaquePointer) -> Int {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    var sql = "SELECT COUNT(DISTINCT value_id) FROM ts_tw_span WHERE \(timeWarpOverlapSQL)"
    if !appBundleIds.isEmpty {
      let marks = appBundleIds.map { _ in "?" }.joined(separator: ",")
      sql += " AND app_id IN (SELECT id FROM ts_tw_value WHERE domain = 'app' AND value IN (\(marks)))"
    }
    guard sqlite3_prepare_v2(db, sql + ";", -1, &stmt, nil) == SQLITE_OK else { return 0 }
    bindTimeWarpOverlap(stmt, fromMs: fromMs, toMs: toMs)
    for (index, bundleId) in appBundleIds.enumerated() {
      sqlite3_bind_text(stmt, Int32(4 + index), bundleId, -1, SQLITE_TRANSIENT)
    }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  /// When a deleted frame stops standing for the screen: the next frame, at most ten minutes later.
  static func timeWarpFrameEndMs(startedAtMs: Int64, db: OpaquePointer) -> Int64 {
    let cap = startedAtMs + 10 * 60_000
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = "SELECT MIN(started_at_ms) FROM ts_snapshot WHERE started_at_ms > ? AND capture_kind = 'screen';"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return cap }
    sqlite3_bind_int64(stmt, 1, startedAtMs)
    guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return cap }
    return min(cap, sqlite3_column_int64(stmt, 0))
  }

  /// Spans overlapping `[fromMs, toMs)`. A span still in progress is stored ending where it
  /// started, so it counts as running until `nowMs` (at most the span limit).
  static func timeWarpSpans(fromMs: Int64, toMs: Int64, db: OpaquePointer,
                            nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [TimeWarpSpanRecord] {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = """
    SELECT s.kind, s.source, v.value, t.value, a.value, s.start_ms, s.end_ms, s.is_open
    FROM ts_tw_span s
    JOIN ts_tw_value v ON v.id = s.value_id
    LEFT JOIN ts_tw_value t ON t.id = s.title_id
    LEFT JOIN ts_tw_value a ON a.id = s.app_id
    WHERE s.start_ms >= ? AND s.start_ms < ? AND (s.end_ms >= ? OR s.is_open = 1)
    ORDER BY s.start_ms
    LIMIT \(timeWarpRangeRowLimit);
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    bindTimeWarpOverlap(stmt, fromMs: fromMs, toMs: toMs)
    var rows: [TimeWarpSpanRecord] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let kindText = sqlite3_column_text(stmt, 0), let kind = TimeWarpItemKind(rawValue: String(cString: kindText)),
            let sourceText = sqlite3_column_text(stmt, 1), let source = TimeWarpSource(rawValue: String(cString: sourceText)),
            let value = sqlite3_column_text(stmt, 2) else { continue }
      let startMs = sqlite3_column_int64(stmt, 5)
      var endMs = sqlite3_column_int64(stmt, 6)
      if sqlite3_column_int(stmt, 7) == 1 { endMs = max(endMs, min(nowMs, startMs + timeWarpMaxSpanMs)) }
      guard endMs >= fromMs else { continue }
      rows.append(TimeWarpSpanRecord(kind: kind, source: source, value: String(cString: value),
                                     title: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
                                     appBundleId: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                                     startMs: startMs, endMs: endMs))
    }
    return rows
  }

  /// Overlap with `[from, to)`: a span counts if it starts before `to` and ends at or after `from`
  /// (a single moment at `from` counts). Parameters: 1 = earliest start, 2 = to, 3 = from.
  private static let timeWarpOverlapSQL = "start_ms >= ? AND start_ms < ? AND end_ms >= ?"

  private static func bindTimeWarpOverlap(_ stmt: OpaquePointer?, fromMs: Int64, toMs: Int64) {
    sqlite3_bind_int64(stmt, 1, fromMs - timeWarpMaxSpanMs)
    sqlite3_bind_int64(stmt, 2, toMs)
    sqlite3_bind_int64(stmt, 3, fromMs)
  }
}
