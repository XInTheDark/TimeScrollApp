import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

// Internal unified row used to de-duplicate FTS/latest query implementations.
// Not exposed outside this file; higher-level APIs map this to public types.
struct SearchRowUnified: Hashable {
    let id: Int64
    let startedAtMs: Int64
    let path: String
    let appBundleId: String?
    let appName: String?
    let thumbPath: String?
    let content: String? // present only when includeContent == true
}

extension DB {
    // FTS search (multi-app)
    func searchMetas(_ ftsQuery: String,
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) throws -> [SnapshotMeta] {
        // Delegate to unified implementation using a single MATCH part
        let rows = try searchUnified(ftsParts: [ftsQuery],
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        return rows.map { r in
            SnapshotMeta(id: r.id, startedAtMs: r.startedAtMs, path: r.path,
                         appBundleId: r.appBundleId, appName: r.appName, thumbPath: r.thumbPath)
        }
    }

    // FTS search with multiple MATCH parts AND-combined at SQL level
    func searchMetas(_ ftsParts: [String],
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) throws -> [SnapshotMeta] {
        guard !ftsParts.isEmpty else { return [] }
        let rows = try searchUnified(ftsParts: ftsParts,
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        return rows.map { r in
            SnapshotMeta(id: r.id, startedAtMs: r.startedAtMs, path: r.path,
                         appBundleId: r.appBundleId, appName: r.appName, thumbPath: r.thumbPath)
        }
    }

    // Paged search with raw text content for snippet UI (multi-app)
    func searchWithContent(_ ftsQuery: String,
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil,
                           limit: Int = 50,
                           offset: Int = 0) throws -> [SearchResult] {
        let rows = try searchUnified(ftsParts: [ftsQuery],
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        let results = rows.map { r in
            SearchResult(id: r.id, startedAtMs: r.startedAtMs, path: r.path,
                         appBundleId: r.appBundleId, appName: r.appName, thumbPath: r.thumbPath,
                         content: "")
        }
        return try hydrateSearchResultContents(results)
    }

    // FTS search with multiple MATCH parts AND-combined at SQL level (with content)
    func searchWithContent(_ ftsParts: [String],
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil,
                           limit: Int = 50,
                           offset: Int = 0) throws -> [SearchResult] {
        guard !ftsParts.isEmpty else { return [] }
        let rows = try searchUnified(ftsParts: ftsParts,
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        let results = rows.map { r in
            SearchResult(id: r.id, startedAtMs: r.startedAtMs, path: r.path,
                         appBundleId: r.appBundleId, appName: r.appName, thumbPath: r.thumbPath,
                         content: "")
        }
        return try hydrateSearchResultContents(results)
    }

    /// Core FTS search used by both `searchMetas` and `searchWithContent` wrappers.
    private func searchUnified(ftsParts: [String],
                               appBundleIds: [String]?,
                               startMs: Int64?,
                               endMs: Int64?,
                               limit: Int,
                               offset: Int,
                               includeContent: Bool) throws -> [SearchRowUnified] {
        try onQueueSync {
            guard !ftsParts.isEmpty else { return [] }
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path
            FROM ts_snapshot s
            WHERE 1=1
            """
            // Add one MATCH per part to preserve per-token OR-group semantics across both
            // the new chunk index and the legacy single-row FTS table.
            for _ in ftsParts {
                sql += """
                 AND s.id IN (
                    SELECT snapshot_id FROM ts_text_chunk WHERE content MATCH ?
                    UNION
                    SELECT rowid AS snapshot_id FROM ts_text WHERE content MATCH ?
                 )
                """
            }
            if let s = startMs { sql += " AND s.started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND s.started_at_ms <= \(e)" }
            if let ids = appBundleIds, !ids.isEmpty {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                sql += " AND s.app_bundle_id IN (\(placeholders))"
            }
            sql += " ORDER BY s.started_at_ms DESC LIMIT ? OFFSET ?;"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            for p in ftsParts {
                sqlite3_bind_text(stmt, idx, p, -1, SQLITE_TRANSIENT); idx += 1
                sqlite3_bind_text(stmt, idx, p, -1, SQLITE_TRANSIENT); idx += 1
            }
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SearchRowUnified] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                rows.append(SearchRowUnified(id: id, startedAtMs: ts, path: path,
                                             appBundleId: bid, appName: name, thumbPath: thumb,
                                             content: includeContent ? "" : nil))
            }
            return rows
        }
    }

}
