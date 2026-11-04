import Foundation
import SQLCipher
@testable import TimeScroll

/// A throwaway database file with the summary schema. It never touches `DB.shared`, so the user's
/// storage location and database are left alone.
final class SummaryTestDatabase: SummaryDatabase, @unchecked Sendable {
  private let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("summaries-\(UUID().uuidString).sqlite")
  let db: OpaquePointer
  var storedTexts: [Int64: String] = [:]
  var isLocked = false
  private var nextId: Int64 = 1

  init() throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "test", code: 1) }
    db = handle
    BenchmarkEncryption.applyIfRequested(to: db)
    exec("""
    CREATE TABLE ts_snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at_ms INTEGER NOT NULL, app_bundle_id TEXT, app_name TEXT,
                              text_ref_id INTEGER, text_store_id INTEGER, capture_kind TEXT NOT NULL DEFAULT 'screen');
    CREATE INDEX idx_capture ON ts_snapshot(capture_kind, started_at_ms DESC);
    CREATE INDEX idx_app ON ts_snapshot(app_bundle_id, started_at_ms DESC);
    CREATE TABLE ts_embedding (snapshot_id INTEGER NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL, updated_at_ms INTEGER NOT NULL,
                               provider TEXT NOT NULL DEFAULT 'apple-nl', model TEXT NOT NULL DEFAULT '');
    CREATE UNIQUE INDEX idx_embedding_identity ON ts_embedding(snapshot_id, provider, model);
    """)
    DB.createMetaTableIfNeeded(db: db)
    DB.createSummaryTablesIfNeeded(db: db)
  }

  deinit {
    sqlite3_close(db)
    try? FileManager.default.removeItem(at: url)
  }

  func exec(_ sql: String) {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    precondition(result == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
  }

  /// A screen with text, and its embedding when `vector` is set.
  func addScreen(at time: Int64, textId: Int64, vector: [Float]? = nil, provider: String = "p", model: String = "m") {
    exec("INSERT INTO ts_snapshot(started_at_ms, app_bundle_id, text_store_id, capture_kind) VALUES(\(time), 'com.a', \(textId), 'screen');")
    guard let vector else { return }
    addEmbedding(snapshotId: sqlite3_last_insert_rowid(db), vector: vector, provider: provider, model: model)
  }

  func addEmbedding(snapshotId: Int64, vector: [Float], provider: String = "p", model: String = "m") {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "INSERT INTO ts_embedding(snapshot_id, dim, vec, updated_at_ms, provider, model) VALUES(?, ?, ?, 0, ?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
    sqlite3_bind_int64(stmt, 1, snapshotId)
    sqlite3_bind_int(stmt, 2, Int32(vector.count))
    vector.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
    sqlite3_bind_text(stmt, 4, provider, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 5, model, -1, SQLITE_TRANSIENT)
    _ = sqlite3_step(stmt)
  }

  func addCapture(at time: Int64, app: String? = "com.app", name: String? = nil, kind: String = "screen") {
    let quoted = app.map { "'\($0)'" } ?? "NULL"
    let nameSQL = (name ?? app).map { "'\($0)'" } ?? "NULL"
    exec("INSERT INTO ts_snapshot(id, started_at_ms, app_bundle_id, app_name, capture_kind) VALUES(\(nextId), \(time), \(quoted), \(nameSQL), '\(kind)');")
    nextId += 1
  }

  func addCaptures(_ captures: [(time: Int64, app: String)]) {
    exec("BEGIN;")
    for capture in captures { addCapture(at: capture.time, app: capture.app) }
    exec("COMMIT;")
  }

  func count(_ sql: String) -> Int {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  // MARK: - SummaryDatabase

  func read<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    if isLocked { throw NSError(domain: "TS.DB", code: -100) }
    return try body(db)
  }

  func write<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    if isLocked { throw NSError(domain: "TS.DB", code: -100) }
    exec("SAVEPOINT test_write;")
    do {
      let value = try body(db)
      exec("RELEASE SAVEPOINT test_write;")
      return value
    } catch {
      exec("ROLLBACK TO SAVEPOINT test_write; RELEASE SAVEPOINT test_write;")
      throw error
    }
  }

  func texts(ids: [Int64]) throws -> [Int64: String] {
    if isLocked { throw NSError(domain: "TS.DB", code: -100) }
    return storedTexts.filter { ids.contains($0.key) }
  }
}

/// Fixed calendars and times, so tests don't depend on the machine's time zone or clock.
enum SummaryTestTime {
  static func calendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.firstWeekday = 2
    return calendar
  }

  static func ms(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, second: Int = 0, zone: String = "UTC") -> Int64 {
    let date = calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    return Int64(date.timeIntervalSince1970 * 1000)
  }
}
