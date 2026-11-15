import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
  /// Rewrites every stored media path under `oldRoot` (screen media, posters and audio assets)
  /// to live under `newRoot`, in one transaction. Throws when the database is not open or the
  /// update fails, so a caller never mistakes a skipped rewrite for a finished one.
  @discardableResult
  func rewriteMediaPathsAfterRootMove(oldRoot: String, newRoot: String) throws -> Int {
    try onQueueSync {
      guard let db = db else {
        throw NSError(domain: "TS.DB", code: 120, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
      }
      return try Self.rewriteMediaPaths(db: db, oldRoot: oldRoot, newRoot: newRoot)
    }
  }

  static func rewriteMediaPaths(db: OpaquePointer, oldRoot: String, newRoot: String) throws -> Int {
    let oldPrefix = oldRoot.hasSuffix("/") ? oldRoot : oldRoot + "/"
    let newPrefix = newRoot.hasSuffix("/") ? newRoot : newRoot + "/"
    try SQLCipherSettings.exec(db, "BEGIN IMMEDIATE;")
    do {
      var changed = 0
      for (table, column) in [("ts_snapshot", "path"), ("ts_snapshot", "thumb_path"), ("ts_audio_asset", "path")] {
        changed += try replacePrefix(db: db, table: table, column: column, oldPrefix: oldPrefix, newPrefix: newPrefix)
      }
      try SQLCipherSettings.exec(db, "COMMIT;")
      return changed
    } catch {
      _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      throw error
    }
  }

  /// The newest stored media paths, to confirm a move left them resolvable.
  func recentMediaPaths(limit: Int) throws -> [String] {
    try onQueueSync {
      guard let db = db else {
        throw NSError(domain: "TS.DB", code: 120, userInfo: [NSLocalizedDescriptionKey: "Database not open"])
      }
      var stmt: OpaquePointer?
      defer { sqlite3_finalize(stmt) }
      let sql = "SELECT path FROM ts_snapshot ORDER BY id DESC LIMIT ?1;"
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLCipherSettings.error(db, "Query failed") }
      sqlite3_bind_int(stmt, 1, Int32(limit))
      var paths: [String] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        if let c = sqlite3_column_text(stmt, 0) { paths.append(String(cString: c)) }
      }
      return paths
    }
  }

  /// Swaps `oldPrefix` for `newPrefix` wherever the value starts with it. Compares the leading
  /// characters exactly: `LIKE` would treat `%`/`_` in folder names as wildcards (and is
  /// case-insensitive), and `REPLACE` would also rewrite later occurrences.
  private static func replacePrefix(db: OpaquePointer, table: String, column: String, oldPrefix: String, newPrefix: String) throws -> Int {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = "UPDATE \(table) SET \(column) = ?2 || substr(\(column), length(?1) + 1) WHERE substr(\(column), 1, length(?1)) = ?1;"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLCipherSettings.error(db, "Path update failed") }
    sqlite3_bind_text(stmt, 1, oldPrefix, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 2, newPrefix, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLCipherSettings.error(db, "Path update failed") }
    return Int(sqlite3_changes(db))
  }
}
