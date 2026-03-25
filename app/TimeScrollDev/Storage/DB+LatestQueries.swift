import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    func latest(limit: Int = 100) throws -> [String] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT path FROM ts_snapshot ORDER BY started_at_ms DESC LIMIT ?;", -1, &stmt, nil) != SQLITE_OK {
                return []
            }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var results: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    results.append(String(cString: cstr))
                }
            }
            return results
        }
    }

    // latestPaths removed in favor of latestMetas

    // Batched meta fetch for timeline/search views (multi-app)
    func latestMetas(limit: Int = 1000,
                     offset: Int = 0,
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil) throws -> [SnapshotMeta] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT id, started_at_ms, path, app_bundle_id, app_name, thumb_path
            FROM ts_snapshot
            WHERE 1=1
            """
            if let s = startMs { sql += " AND started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND started_at_ms <= \(e)" }
            if let ids = appBundleIds, !ids.isEmpty {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                sql += " AND app_bundle_id IN (\(placeholders))"
            }
            sql += " ORDER BY started_at_ms DESC LIMIT ? OFFSET ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids {
                    sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT)
                    idx += 1
                }
            }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SnapshotMeta] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                rows.append(SnapshotMeta(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name, thumbPath: thumb))
            }
            return rows
        }
    }

    // Fetch a single snapshot meta by id
    func snapshotMetaById(_ id: Int64) throws -> SnapshotMeta? {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, started_at_ms, path, app_bundle_id, app_name, thumb_path FROM ts_snapshot WHERE id=? LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_int64(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                return SnapshotMeta(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name, thumbPath: thumb)
            }
            return nil
        }
    }

    func updateThumbPath(rowId: Int64, thumbPath: String?) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "UPDATE ts_snapshot SET thumb_path=? WHERE id=?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
            if let p = thumbPath {
                sqlite3_bind_text(stmt, 1, p, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int64(stmt, 2, rowId)
            _ = sqlite3_step(stmt)
        }
    }

    // Return (id, thumbPath) for rows with posters in the range [startMs, endMs]
    func rowsWithThumbs(startMs: Int64, endMs: Int64) throws -> [(Int64, String)] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            let sql = "SELECT id, thumb_path FROM ts_snapshot WHERE started_at_ms >= ? AND started_at_ms <= ? AND thumb_path IS NOT NULL;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(stmt, 1, startMs)
            sqlite3_bind_int64(stmt, 2, endMs)
            var out: [(Int64, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                if let c = sqlite3_column_text(stmt, 1) {
                    out.append((id, String(cString: c)))
                }
            }
            return out
        }
    }

    // Latest with content (for empty query) to show snippet-like previews consistently (multi-app)
    func latestWithContent(limit: Int = 50,
                           offset: Int = 0,
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil) throws -> [SearchResult] {
        let rows = try latestUnified(limit: limit,
                                     offset: offset,
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     includeContent: false)
        let results = rows.map { r in
            SearchResult(id: r.id, startedAtMs: r.startedAtMs, path: r.path,
                         appBundleId: r.appBundleId, appName: r.appName, thumbPath: r.thumbPath,
                         content: "")
        }
        return try hydrateSearchResultContents(results)
    }

    /// Core latest page helper backing both meta and content variants.
    private func latestUnified(limit: Int,
                               offset: Int,
                               appBundleIds: [String]?,
                               startMs: Int64?,
                               endMs: Int64?,
                               includeContent: Bool) throws -> [SearchRowUnified] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            let selectClause = includeContent
                ? "SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, t.content"
                : "SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path"
            let fromClause = includeContent
                ? "FROM ts_snapshot s LEFT JOIN ts_text t ON t.rowid = s.id"
                : "FROM ts_snapshot s"
            var sql = """
            \(selectClause)
            \(fromClause)
            WHERE 1=1
            """
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
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids {
                    sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT)
                    idx += 1
                }
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
                let content: String?
                if includeContent {
                    content = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                } else {
                    content = nil
                }
                rows.append(SearchRowUnified(id: id, startedAtMs: ts, path: path,
                                             appBundleId: bid, appName: name, thumbPath: thumb,
                                             content: content))
            }
            return rows
        }
    }
}
