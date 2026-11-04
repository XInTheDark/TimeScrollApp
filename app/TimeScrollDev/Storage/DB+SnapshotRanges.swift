import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Counting and deleting the snapshots of a time range.
extension DB {
  struct SnapshotRangeCount: Equatable, Sendable {
    var screen = 0
    var audio = 0
    var total: Int { screen + audio }
  }

  struct SnapshotRangeBatch: Equatable {
    let removed: Int
    let files: [String]
  }

  /// One transaction at most this large, so capture writes on the same queue wait only briefly.
  static let snapshotRangeBatchSize = 500
  /// The same margin retention uses for media that a 60 s segment shares across rows.
  private static let mediaShareWindowMs: Int64 = 5 * 60_000

  func countSnapshots(matching filter: SnapshotRangeFilter) throws -> SnapshotRangeCount {
    try onReadQueueSync { db in Self.countSnapshots(matching: filter, db: db) }
  }

  /// Deletes in batches, then removes each batch's media once it is committed. `progress` receives
  /// the rows removed so far. Throws if the database becomes unavailable, leaving the rest in place.
  @discardableResult
  func deleteSnapshots(matching filter: SnapshotRangeFilter, progress: (Int) -> Void = { _ in }) throws -> Int {
    var removed = 0
    let fm = FileManager.default
    defer { if removed > 0 { purgeOrphanedAudioAssets() } }
    while true {
      let batch = try onQueueSync { () -> SnapshotRangeBatch in
        try openIfNeeded()
        guard let db = db else { throw NSError(domain: "TS.DB", code: 3) }
        return try Self.deleteSnapshotBatch(matching: filter, limit: Self.snapshotRangeBatchSize,
                                            nowMs: Int64(Date().timeIntervalSince1970 * 1000), db: db)
      }
      for file in batch.files { _ = try? fm.removeItem(atPath: file) }
      guard batch.removed > 0 else { return removed }
      removed += batch.removed
      progress(removed)
    }
  }

  static func countSnapshots(matching filter: SnapshotRangeFilter, db: OpaquePointer) -> SnapshotRangeCount {
    // One count per kind: each stays on an index, where grouping would read every row.
    func count(_ kind: CaptureKind) -> Int {
      guard filter.captureKinds.isEmpty || filter.captureKinds.contains(kind) else { return 0 }
      var stmt: OpaquePointer?
      defer { sqlite3_finalize(stmt) }
      let sql = "SELECT COUNT(*) FROM ts_snapshot WHERE \(filter.whereSQL) AND capture_kind = '\(kind.rawValue)';"
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
      return Int(sqlite3_column_int64(stmt, 0))
    }
    return SnapshotRangeCount(screen: count(.screen), audio: count(.audio))
  }

  /// Deletes up to `limit` matching snapshots, oldest first, and returns the media no remaining row uses.
  static func deleteSnapshotBatch(matching filter: SnapshotRangeFilter, limit: Int, nowMs: Int64, db: OpaquePointer) throws -> SnapshotRangeBatch {
    struct Row {
      let id: Int64
      let path: String?
      let thumbPath: String?
      let startedAtMs: Int64
      let textStoreId: Int64?
    }
    var rows: [Row] = []
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let select = "SELECT id, path, thumb_path, started_at_ms, text_store_id FROM ts_snapshot WHERE \(filter.whereSQL) ORDER BY started_at_ms LIMIT \(limit);"
    guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { throw rangeError(db) }
    while sqlite3_step(stmt) == SQLITE_ROW {
      rows.append(Row(id: sqlite3_column_int64(stmt, 0),
                      path: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                      thumbPath: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                      startedAtMs: sqlite3_column_int64(stmt, 3),
                      textStoreId: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)))
    }
    guard let first = rows.first, let last = rows.last else { return SnapshotRangeBatch(removed: 0, files: []) }

    let ids = rows.map { String($0.id) }.joined(separator: ",")
    let textStoreIds = Set(rows.compactMap(\.textStoreId)).map(String.init).joined(separator: ",")
    let sql = """
    BEGIN IMMEDIATE;
    \(textIndexDeletionSQL(snapshotIdsSQL: ids, legacyTablesExist: legacyTextTablesExist(db: db)))
    \(ocrLayoutDeletionSQL(snapshotIdsSQL: ids))
    DELETE FROM ts_embedding WHERE snapshot_id IN (\(ids));
    DELETE FROM ts_snapshot WHERE id IN (\(ids));
    \(unusedTextDeletionSQL(textStoreIds: textStoreIds))
    \(sessionDayInvalidationSQL(windowsFromMs: first.startedAtMs, throughMs: last.startedAtMs))
    \(summaryInvalidationSQL(capturesFromMs: first.startedAtMs, throughMs: last.startedAtMs))
    COMMIT;
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      let error = rangeError(db)
      _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      throw error
    }

    let remaining = mediaInUse(aroundTimes: rows.map(\.startedAtMs), db: db)
    var checked = Set<String>()
    var files: [String] = []
    for row in rows {
      let unchecked: (String?) -> String? = { path in path.flatMap { checked.insert($0).inserted ? $0 : nil } }
      files += DeletedSnapshotMedia.filesToRemove(path: unchecked(row.path), thumbPath: unchecked(row.thumbPath),
                                                  startedAtMs: row.startedAtMs, nowMs: nowMs) { file in
        // Unknown (query failed) counts as referenced, so the file is kept.
        guard let remaining else { return true }
        return DeletedSnapshotMedia.equivalentPaths(of: file).contains { remaining.contains($0) }
      }
    }
    return SnapshotRangeBatch(removed: rows.count, files: files)
  }

  /// Checks only the removed rows' texts. The retention and single-delete statements scan every
  /// text, which is too slow to repeat for each batch of a long range.
  private static func unusedTextDeletionSQL(textStoreIds ids: String) -> String {
    guard !ids.isEmpty else { return "" }
    return """
    DELETE FROM ts_text_store WHERE id IN (\(ids)) AND id NOT IN (SELECT text_store_id FROM ts_snapshot WHERE text_store_id IN (\(ids)));
    DELETE FROM ts_session_sketch WHERE text_store_id IN (\(ids)) AND text_store_id NOT IN (SELECT id FROM ts_text_store WHERE id IN (\(ids)));
    """
  }

  /// Media of the remaining rows near `times` (ascending); nil if a query fails. Rows share media
  /// only within one segment, about a minute, so looking nearby is enough and avoids scanning the
  /// table for each file: `path` has no index.
  static func mediaInUse(aroundTimes times: [Int64], db: OpaquePointer) -> Set<String>? {
    var windows: [(from: Int64, to: Int64)] = []
    for time in times {
      if let last = windows.last, time - mediaShareWindowMs <= last.to {
        windows[windows.count - 1].to = time + mediaShareWindowMs
      } else {
        windows.append((time - mediaShareWindowMs, time + mediaShareWindowMs))
      }
    }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = "SELECT path, thumb_path FROM ts_snapshot WHERE started_at_ms >= ? AND started_at_ms <= ?;"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    var paths = Set<String>()
    for window in windows {
      sqlite3_reset(stmt)
      sqlite3_bind_int64(stmt, 1, window.from)
      sqlite3_bind_int64(stmt, 2, window.to)
      var step = sqlite3_step(stmt)
      while step == SQLITE_ROW {
        if let path = sqlite3_column_text(stmt, 0) { paths.insert(String(cString: path)) }
        if let thumb = sqlite3_column_text(stmt, 1) { paths.insert(String(cString: thumb)) }
        step = sqlite3_step(stmt)
      }
      guard step == SQLITE_DONE else { return nil }
    }
    return paths
  }

  private static func rangeError(_ db: OpaquePointer) -> NSError {
    NSError(domain: "TS.DB", code: 82, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
  }
}
