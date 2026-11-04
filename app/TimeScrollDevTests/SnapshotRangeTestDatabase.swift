import Foundation
import SQLCipher
@testable import TimeScroll

/// A throwaway database with the tables a range delete touches. It never touches `DB.shared`.
final class SnapshotRangeTestDatabase: @unchecked Sendable {
  private let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ranges-\(UUID().uuidString).sqlite")
  let db: OpaquePointer

  init() throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "test", code: 1) }
    db = handle
    BenchmarkEncryption.applyIfRequested(to: db)
    exec("""
    CREATE TABLE ts_snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at_ms INTEGER NOT NULL, path TEXT NOT NULL, thumb_path TEXT,
                              app_bundle_id TEXT, app_name TEXT, text_ref_id INTEGER, text_store_id INTEGER, audio_asset_id INTEGER,
                              capture_kind TEXT NOT NULL DEFAULT 'screen', source_kind TEXT);
    CREATE INDEX idx_started ON ts_snapshot(started_at_ms DESC);
    CREATE INDEX idx_app ON ts_snapshot(app_bundle_id, started_at_ms DESC);
    CREATE INDEX idx_capture ON ts_snapshot(capture_kind, started_at_ms DESC);
    CREATE INDEX idx_source ON ts_snapshot(source_kind, started_at_ms DESC);
    CREATE INDEX idx_store ON ts_snapshot(text_store_id);
    CREATE TABLE ts_embedding (snapshot_id INTEGER NOT NULL);
    CREATE INDEX idx_embedding ON ts_embedding(snapshot_id);
    CREATE TABLE ts_ocr_boxes (snapshot_id INTEGER NOT NULL);
    CREATE INDEX idx_boxes ON ts_ocr_boxes(snapshot_id);
    CREATE TABLE ts_ocr_layout (snapshot_id INTEGER PRIMARY KEY, data BLOB NOT NULL);
    CREATE TABLE ts_text_store (id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT);
    CREATE TABLE ts_session_sketch (text_store_id INTEGER PRIMARY KEY, sketch BLOB NOT NULL);
    CREATE TABLE ts_session_day (day_start_ms INTEGER PRIMARY KEY, window_start_ms INTEGER NOT NULL, window_end_ms INTEGER NOT NULL);
    CREATE VIRTUAL TABLE ts_text_index USING fts5(content, content='', contentless_delete=1);
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

  func count(_ sql: String) -> Int {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  /// A snapshot and everything stored with it. Text is shared when `textStoreId` repeats.
  @discardableResult
  func addSnapshot(at time: Int64, path: String? = nil, thumbPath: String? = nil, app: String = "com.a", kind: String = "screen",
                   source: String? = nil, textStoreId: Int64? = nil) -> Int64 {
    let thumb = thumbPath.map { "'\($0)'" } ?? "NULL"
    let store = textStoreId.map(String.init) ?? "NULL"
    let sourceSQL = source.map { "'\($0)'" } ?? "NULL"
    exec("""
    INSERT INTO ts_snapshot(started_at_ms, path, thumb_path, app_bundle_id, capture_kind, source_kind, text_store_id)
    VALUES(\(time), '\(path ?? "/media/\(time).heic")', \(thumb), '\(app)', '\(kind)', \(sourceSQL), \(store));
    """)
    let id = sqlite3_last_insert_rowid(db)
    exec("""
    INSERT INTO ts_embedding(snapshot_id) VALUES(\(id));
    INSERT INTO ts_ocr_boxes(snapshot_id) VALUES(\(id));
    INSERT INTO ts_ocr_layout(snapshot_id, data) VALUES(\(id), x'00');
    INSERT INTO ts_text_index(rowid, content) VALUES(\(id), 'words');
    """)
    if let textStoreId {
      exec("""
      INSERT OR IGNORE INTO ts_text_store(id, content) VALUES(\(textStoreId), 'text');
      INSERT OR IGNORE INTO ts_session_sketch(text_store_id, sketch) VALUES(\(textStoreId), x'00');
      """)
    }
    return id
  }

  /// Runs batches until nothing matches; returns the rows removed and all media to remove.
  func deleteAll(matching filter: SnapshotRangeFilter, limit: Int = 500, nowMs: Int64 = 10_000_000_000_000) throws -> (removed: Int, files: [String]) {
    var removed = 0
    var files: [String] = []
    while true {
      let batch = try DB.deleteSnapshotBatch(matching: filter, limit: limit, nowMs: nowMs, db: db)
      files += batch.files
      guard batch.removed > 0 else { return (removed, files) }
      removed += batch.removed
    }
  }
}
