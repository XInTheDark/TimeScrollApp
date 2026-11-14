import Foundation
import SQLCipher
@testable import TimeScroll

/// A throwaway database with the Time Warp tables. It never touches `DB.shared` or its string cache.
final class TimeWarpTestDatabase: @unchecked Sendable {
  private let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("timewarp-\(UUID().uuidString).sqlite")
  let db: OpaquePointer
  let cache = TimeWarpValueCache()

  init() throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "test", code: 1) }
    db = handle
    BenchmarkEncryption.applyIfRequested(to: db)
    exec("CREATE TABLE ts_snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at_ms INTEGER NOT NULL, capture_kind TEXT NOT NULL DEFAULT 'screen');")
    DB.createTimeWarpTablesIfNeeded(db: db)
  }

  deinit {
    sqlite3_close(db)
    try? FileManager.default.removeItem(at: url)
  }

  func exec(_ sql: String) {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    precondition(result == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
  }

  func count(_ sql: String) -> Int {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  @discardableResult
  func add(_ value: String, kind: TimeWarpItemKind = .page, source: TimeWarpSource = .front, title: String? = nil,
           app: String? = "com.a", start: Int64, end: Int64, isOpen: Bool = false) -> Int64 {
    let item = TimeWarpItem(kind: kind, value: value, title: title)
    let span = TimeWarpSpanStart(item: item, source: source, appBundleId: app, startMs: start)
    return DB.timeWarpInsert(span, endMs: end, isOpen: isOpen, db: db, cache: cache)!
  }

  func spans(_ from: Int64 = .min / 4, _ to: Int64 = .max / 4) -> [TimeWarpSpanRecord] {
    DB.timeWarpSpans(fromMs: from, toMs: to, db: db)
  }

  func isOpen(_ id: Int64) -> Bool { count("SELECT is_open FROM ts_tw_span WHERE id = \(id);") == 1 }

  func delete(_ from: Int64, _ to: Int64, apps: [String] = []) throws {
    try DB.deleteTimeWarpRecords(fromMs: from, toMs: to, appBundleIds: apps, db: db)
    cache.removeAll()
  }
}
