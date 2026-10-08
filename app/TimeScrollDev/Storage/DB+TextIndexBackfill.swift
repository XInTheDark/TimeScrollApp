import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// One-time migration of rows indexed by the legacy `ts_text`/`ts_text_chunk` tables into
/// `ts_text_store` + `ts_text_index`. Progress is kept in `ts_meta`, so it resumes after restarts.
extension DB {
    enum TextIndexBackfillStep {
        case progressed(Int)
        case done
    }

    private static let backfillUpperKey = "text_index_backfill_upper"
    private static let backfillCursorKey = "text_index_backfill_cursor"

    /// Migrates up to `limit` rows in one transaction. When no rows remain, drops the legacy tables.
    func backfillTextIndexBatch(limit: Int) throws -> TextIndexBackfillStep {
        try withWriteSavepoint {
            try openIfNeeded()
            guard let db = db else { return .done }
            guard Self.legacyTextTablesExist(db: db) else { return .done }

            // Rows above `upper` were written after the new index existed and are already indexed.
            let upper: Int64
            if let stored = Self.metaInt(Self.backfillUpperKey, db: db) {
                upper = stored
            } else {
                upper = Self.maxSnapshotId(db: db)
                try Self.setMetaInt(Self.backfillUpperKey, upper, db: db)
            }
            let cursor = Self.metaInt(Self.backfillCursorKey, db: db) ?? 0

            let rows = Self.snapshotTextRefs(after: cursor, upTo: upper, limit: limit, db: db)
            guard let lastId = rows.last?.id else {
                for table in Self.legacyTextTables {
                    _ = sqlite3_exec(db, "DROP TABLE IF EXISTS \(table);", nil, nil, nil)
                }
                return .done
            }

            var cache: [Int64: String?] = [:]
            for row in rows {
                if row.textStoreId > 0, let text = loadStoredText(textStoreId: row.textStoreId, db: db) {
                    try Self.indexText(rowId: row.id, content: text, db: db)
                    continue
                }
                // Reference rows and preview-only rows get their own text-store entry
                // (de-duplicated by hash), which also indexes them.
                var visited: Set<Int64> = []
                if let text = try resolvedTextContent(snapshotId: row.id, db: db, visited: &visited, cache: &cache),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try storeTextArtifacts(rowId: row.id, content: text, db: db)
                }
            }
            try Self.setMetaInt(Self.backfillCursorKey, lastId, db: db)
            return .progressed(rows.count)
        }
    }

    private static func maxSnapshotId(db: OpaquePointer) -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM ts_snapshot;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func snapshotTextRefs(after cursor: Int64, upTo upper: Int64, limit: Int, db: OpaquePointer) -> [(id: Int64, textStoreId: Int64)] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id, COALESCE(text_store_id, 0) FROM ts_snapshot WHERE id > ? AND id <= ? ORDER BY id LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(stmt, 1, cursor)
        sqlite3_bind_int64(stmt, 2, upper)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var rows: [(id: Int64, textStoreId: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1)))
        }
        return rows
    }
}
