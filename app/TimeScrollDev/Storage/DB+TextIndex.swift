import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Full-text index over snapshot text. The index is contentless: the text itself lives once,
/// compressed and de-duplicated, in `ts_text_store`, and the FTS row id is the snapshot id.
extension DB {
    static let textIndexTable = "ts_text_index"
    /// Pre-index tables kept only until `TextIndexBackfill` has migrated their rows.
    static let legacyTextTables = ["ts_text", "ts_text_chunk"]

    static func createTextIndexIfNeeded(db: OpaquePointer) {
        let sql = "CREATE VIRTUAL TABLE IF NOT EXISTS ts_text_index USING fts5(content, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');"
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    static func legacyTextTablesExist(db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name IN ('ts_text', 'ts_text_chunk') LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Indexes (or re-indexes) a snapshot's text; empty text removes it from the index.
    static func indexText(rowId: Int64, content: String, db: OpaquePointer) throws {
        let document = IndexedTextProjection.indexDocument(from: content)
        guard !document.isEmpty else {
            try removeFromTextIndex(rowId: rowId, db: db)
            return
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ts_text_index(rowid, content) VALUES(?, ?);", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.DB", code: 610, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        sqlite3_bind_int64(stmt, 1, rowId)
        sqlite3_bind_text(stmt, 2, document, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "TS.DB", code: 611, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    static func removeFromTextIndex(rowId: Int64, db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM ts_text_index WHERE rowid=?;", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.DB", code: 612, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        sqlite3_bind_int64(stmt, 1, rowId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "TS.DB", code: 613, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// SQL fragment selecting snapshot ids whose text matches one bound FTS expression
    /// per `?`. While legacy tables still exist, their rows are matched as well.
    static func textMatchSubquery(legacyTablesExist: Bool) -> (sql: String, bindsPerPart: Int) {
        guard legacyTablesExist else {
            return ("SELECT rowid FROM ts_text_index WHERE ts_text_index MATCH ?", 1)
        }
        let sql = """
        SELECT rowid FROM ts_text_index WHERE ts_text_index MATCH ?
        UNION SELECT snapshot_id FROM ts_text_chunk WHERE ts_text_chunk MATCH ?
        UNION SELECT rowid FROM ts_text WHERE ts_text MATCH ?
        """
        return (sql, 3)
    }

    /// Statements that delete index rows for snapshots selected by `snapshotIdsSQL`.
    static func textIndexDeletionSQL(snapshotIdsSQL: String, legacyTablesExist: Bool) -> String {
        var sql = "DELETE FROM ts_text_index WHERE rowid IN (\(snapshotIdsSQL));\n"
        if legacyTablesExist {
            sql += "DELETE FROM ts_text WHERE rowid IN (\(snapshotIdsSQL));\n"
            sql += "DELETE FROM ts_text_chunk WHERE snapshot_id IN (\(snapshotIdsSQL));\n"
        }
        return sql
    }
}
