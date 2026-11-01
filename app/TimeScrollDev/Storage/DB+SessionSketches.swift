import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// One screen capture reduced to what session segmentation reads.
struct SessionSampleRow: Equatable {
  let snapshotId: Int64
  let timeMs: Int64
  let appBundleId: String?
  let appName: String?
  /// Nil while the capture has no text (OCR pending or nothing on screen).
  let textStoreId: Int64?
  /// Nil when the text exists but has no sketch yet.
  let sketch: [UInt32]?
}

/// Session sketches live in their own small table keyed by text (`ts_text_store` row), so reading a
/// day's sketches never touches the compressed texts. Identical screens share one sketch.
extension DB {
  static func createSessionSketchTableIfNeeded(db: OpaquePointer) {
    _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ts_session_sketch (text_store_id INTEGER PRIMARY KEY, sketch BLOB NOT NULL);", nil, nil, nil)
  }

  /// SQL removing sketches whose text is gone; appended to the statements that delete texts.
  static let orphanedSessionSketchDeletionSQL =
    "DELETE FROM ts_session_sketch WHERE text_store_id NOT IN (SELECT id FROM ts_text_store);"

  /// Called when a snapshot's text is stored; computes the sketch only for text not seen before.
  static func storeSessionSketchIfMissing(textStoreId: Int64, content: String, db: OpaquePointer) {
    var lookup: OpaquePointer?
    defer { sqlite3_finalize(lookup) }
    guard sqlite3_prepare_v2(db, "SELECT 1 FROM ts_session_sketch WHERE text_store_id=? LIMIT 1;", -1, &lookup, nil) == SQLITE_OK else { return }
    sqlite3_bind_int64(lookup, 1, textStoreId)
    guard sqlite3_step(lookup) != SQLITE_ROW else { return }
    writeSessionSketch(SessionTextSketch.make(from: content), textStoreId: textStoreId, db: db)
  }

  static func writeSessionSketch(_ sketch: [UInt32], textStoreId: Int64, db: OpaquePointer) {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ts_session_sketch(text_store_id, sketch) VALUES(?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
    sqlite3_bind_int64(stmt, 1, textStoreId)
    let data = SessionTextSketch.encode(sketch)
    if data.isEmpty {
      // A zero-length blob, not NULL: "no words" is a computed result.
      sqlite3_bind_zeroblob(stmt, 2, 0)
    } else {
      _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
    }
    _ = sqlite3_step(stmt)
  }

  /// Screen captures that started in `[fromMs, toMs)`, oldest first, with their sketches.
  func sessionSampleRows(fromMs: Int64, toMs: Int64) throws -> [SessionSampleRow] {
    try onReadQueueSync { db in try Self.sessionSampleRows(fromMs: fromMs, toMs: toMs, db: db) }
  }

  static func sessionSampleRows(fromMs: Int64, toMs: Int64, db: OpaquePointer) throws -> [SessionSampleRow] {
    let sql = """
    SELECT s.id, s.started_at_ms, s.app_bundle_id, s.app_name,
           COALESCE(s.text_store_id, r.text_store_id), k.sketch, k.text_store_id IS NOT NULL
    FROM ts_snapshot s
    LEFT JOIN ts_snapshot r ON s.text_store_id IS NULL AND r.id = s.text_ref_id
    LEFT JOIN ts_session_sketch k ON k.text_store_id = COALESCE(s.text_store_id, r.text_store_id)
    WHERE s.capture_kind = 'screen' AND s.started_at_ms >= ? AND s.started_at_ms < ?
    ORDER BY s.started_at_ms ASC, s.id ASC;
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw NSError(domain: "TS.DB", code: 900, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    sqlite3_bind_int64(stmt, 1, fromMs)
    sqlite3_bind_int64(stmt, 2, toMs)
    // Consecutive captures usually share a text; decode each sketch once.
    var decoded: [Int64: [UInt32]] = [:]
    var rows: [SessionSampleRow] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let textStoreId = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
      var sketch: [UInt32]?
      if let textStoreId, sqlite3_column_int(stmt, 6) != 0 {
        if let cached = decoded[textStoreId] {
          sketch = cached
        } else {
          let count = Int(sqlite3_column_bytes(stmt, 5))
          let value = sqlite3_column_blob(stmt, 5).map { SessionTextSketch.decode(UnsafeRawBufferPointer(start: $0, count: count)) } ?? []
          decoded[textStoreId] = value
          sketch = value
        }
      }
      rows.append(SessionSampleRow(snapshotId: sqlite3_column_int64(stmt, 0),
                                   timeMs: sqlite3_column_int64(stmt, 1),
                                   appBundleId: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                                   appName: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
                                   textStoreId: textStoreId,
                                   sketch: sketch))
    }
    return rows
  }

  /// Computes and stores sketches for texts that have none (stored before sessions existed),
  /// returning them. At most `limit` texts per call; the backfill picks up the rest.
  func fillSessionSketches(textStoreIds: [Int64], limit: Int = 5_000) throws -> [Int64: [UInt32]] {
    let ids = Array(textStoreIds.prefix(limit))
    guard !ids.isEmpty else { return [:] }
    let texts = try sessionTexts(textStoreIds: ids)
    var sketches: [Int64: [UInt32]] = [:]
    for id in ids { sketches[id] = texts[id].map(SessionTextSketch.make(from:)) ?? [] }
    try withWriteSavepoint {
      guard let db else { return }
      for (id, sketch) in sketches where texts[id] != nil { Self.writeSessionSketch(sketch, textStoreId: id, db: db) }
    }
    return sketches.filter { texts[$0.key] != nil }
  }

  /// Decompressed texts by `ts_text_store` id; missing ids are left out.
  func sessionTexts(textStoreIds: [Int64]) throws -> [Int64: String] {
    guard !textStoreIds.isEmpty else { return [:] }
    return try onReadQueueSync { db in
      var texts: [Int64: String] = [:]
      for id in Set(textStoreIds) {
        if let text = loadStoredText(textStoreId: id, db: db) { texts[id] = text }
      }
      return texts
    }
  }

  /// Sketches up to `limit` texts that have none, newest first, below `beforeId`. Returns the ids
  /// handled (empty when nothing is left).
  func backfillSessionSketchBatch(beforeId: Int64, limit: Int) throws -> [Int64] {
    let ids = try onReadQueueSync { db in Self.unsketchedTextStoreIds(beforeId: beforeId, limit: limit, db: db) }
    _ = try fillSessionSketches(textStoreIds: ids, limit: limit)
    return ids
  }

  static func unsketchedTextStoreIds(beforeId: Int64, limit: Int, db: OpaquePointer) -> [Int64] {
    let sql = """
    SELECT t.id FROM ts_text_store t
    LEFT JOIN ts_session_sketch k ON k.text_store_id = t.id
    WHERE k.text_store_id IS NULL AND t.id < ?
    ORDER BY t.id DESC LIMIT ?;
    """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_int64(stmt, 1, beforeId)
    sqlite3_bind_int(stmt, 2, Int32(limit))
    var ids: [Int64] = []
    while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
    return ids
  }
}
