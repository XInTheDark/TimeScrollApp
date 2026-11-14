import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// A span to start: what the recorder saw and when.
struct TimeWarpSpanStart: Equatable, Sendable {
  let item: TimeWarpItem
  let source: TimeWarpSource
  let appBundleId: String?
  let startMs: Int64
}

/// Writes for Time Warp: spans of what was in front or open, and single events. Strings are stored
/// once in `ts_tw_value` and referenced by id. A span in progress has `is_open = 1` and is stored
/// ending where it started; it gets its end when it closes.
extension DB {
  /// Longest a stored span may be. The recorder caps longer spans, so a range query only has to
  /// look this far before the range starts (see `timeWarpSpans(from:to:)`).
  static let timeWarpMaxSpanMs: Int64 = 6 * 60 * 60 * 1000

  static let timeWarpValueCache = TimeWarpValueCache()

  static func createTimeWarpTablesIfNeeded(db: OpaquePointer) {
    let sql = """
    CREATE TABLE IF NOT EXISTS ts_tw_value (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain TEXT NOT NULL,
        value TEXT NOT NULL,
        UNIQUE(domain, value)
    );
    CREATE TABLE IF NOT EXISTS ts_tw_span (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        source TEXT NOT NULL,
        value_id INTEGER NOT NULL,
        title_id INTEGER,
        app_id INTEGER,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        is_open INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_ts_tw_span_start ON ts_tw_span(start_ms);
    CREATE INDEX IF NOT EXISTS idx_ts_tw_span_open ON ts_tw_span(is_open) WHERE is_open = 1;
    CREATE INDEX IF NOT EXISTS idx_ts_tw_span_value ON ts_tw_span(value_id);
    CREATE INDEX IF NOT EXISTS idx_ts_tw_span_title ON ts_tw_span(title_id) WHERE title_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_ts_tw_span_warp_point ON ts_tw_span(start_ms) WHERE kind = 'warpPoint';
    """
    _ = sqlite3_exec(db, sql, nil, nil, nil)
  }

  /// Starts an open span; returns its id, or nil if the database is unavailable (locked vault).
  func timeWarpOpenSpan(_ start: TimeWarpSpanStart) -> Int64? {
    timeWarpInsert(start, endMs: start.startMs, isOpen: true)
  }

  /// Records a single moment, such as a finished download or a Warp point.
  @discardableResult
  func timeWarpRecordEvent(_ item: TimeWarpItem, appBundleId: String?, atMs: Int64) -> Bool {
    let start = TimeWarpSpanStart(item: item, source: .event, appBundleId: appBundleId, startMs: atMs)
    return timeWarpInsert(start, endMs: atMs, isOpen: false) != nil
  }

  /// Ends open spans at `endMs` (never before their start).
  func timeWarpCloseSpans(ids: [Int64], endMs: Int64) {
    _ = timeWarpUpdate(ids: ids, sql: Self.timeWarpCloseSQL, endMs: endMs)
  }

  /// Spans left open by a crash or forced quit are closed where they are.
  func timeWarpCloseAbandonedSpans() {
    onQueueSync {
      guard (try? openIfNeeded()) != nil, let db else { return }
      _ = sqlite3_exec(db, "UPDATE ts_tw_span SET is_open = 0 WHERE is_open = 1;", nil, nil, nil)
    }
  }

  private func timeWarpInsert(_ start: TimeWarpSpanStart, endMs: Int64, isOpen: Bool) -> Int64? {
    onQueueSync { () -> Int64? in
      guard (try? openIfNeeded()) != nil, let db else { return nil }
      return Self.timeWarpInsert(start, endMs: endMs, isOpen: isOpen, db: db, cache: Self.timeWarpValueCache)
    }
  }

  private func timeWarpUpdate(ids: [Int64], sql: String, endMs: Int64) -> Set<Int64> {
    guard !ids.isEmpty else { return [] }
    return onQueueSync { () -> Set<Int64> in
      guard (try? openIfNeeded()) != nil, let db else { return [] }
      return Self.timeWarpUpdate(ids: ids, sql: sql, endMs: endMs, db: db)
    }
  }

  static let timeWarpCloseSQL = "UPDATE ts_tw_span SET end_ms = MAX(start_ms, ?), is_open = 0 WHERE id = ? AND is_open = 1;"

  static func timeWarpInsert(_ start: TimeWarpSpanStart, endMs: Int64, isOpen: Bool, db: OpaquePointer, cache: TimeWarpValueCache) -> Int64? {
    guard let valueId = timeWarpValueId(domain: start.item.kind.valueDomain, value: start.item.value, db: db, cache: cache) else { return nil }
    let titleId = start.item.title.flatMap { timeWarpValueId(domain: .title, value: $0, db: db, cache: cache) }
    let appId = start.appBundleId.flatMap { timeWarpValueId(domain: .app, value: $0, db: db, cache: cache) }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = "INSERT INTO ts_tw_span(kind, source, value_id, title_id, app_id, start_ms, end_ms, is_open) VALUES(?,?,?,?,?,?,?,?);"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_text(stmt, 1, start.item.kind.rawValue, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 2, start.source.rawValue, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 3, valueId)
    if let titleId { sqlite3_bind_int64(stmt, 4, titleId) } else { sqlite3_bind_null(stmt, 4) }
    if let appId { sqlite3_bind_int64(stmt, 5, appId) } else { sqlite3_bind_null(stmt, 5) }
    sqlite3_bind_int64(stmt, 6, start.startMs)
    sqlite3_bind_int64(stmt, 7, max(start.startMs, endMs))
    sqlite3_bind_int(stmt, 8, isOpen ? 1 : 0)
    guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
    return sqlite3_last_insert_rowid(db)
  }

  /// Runs `sql` (end, id) for each id; returns the ids it changed.
  static func timeWarpUpdate(ids: [Int64], sql: String, endMs: Int64, db: OpaquePointer) -> Set<Int64> {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    var changed = Set<Int64>()
    for id in ids {
      sqlite3_reset(stmt)
      sqlite3_bind_int64(stmt, 1, endMs)
      sqlite3_bind_int64(stmt, 2, id)
      if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 { changed.insert(id) }
    }
    return changed
  }

  /// The id of a stored string, inserting it if new. Runs on the writer queue.
  private static func timeWarpValueId(domain: TimeWarpValueDomain, value: String, db: OpaquePointer, cache: TimeWarpValueCache) -> Int64? {
    if let cached = cache.id(domain: domain, value: value, db: db) { return cached }
    var insert: OpaquePointer?
    defer { sqlite3_finalize(insert) }
    guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO ts_tw_value(domain, value) VALUES(?, ?);", -1, &insert, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_text(insert, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(insert, 2, value, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(insert) == SQLITE_DONE else { return nil }

    var select: OpaquePointer?
    defer { sqlite3_finalize(select) }
    guard sqlite3_prepare_v2(db, "SELECT id FROM ts_tw_value WHERE domain = ? AND value = ?;", -1, &select, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_text(select, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(select, 2, value, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(select) == SQLITE_ROW else { return nil }
    let id = sqlite3_column_int64(select, 0)
    cache.store(id, domain: domain, value: value)
    return id
  }
}
