import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
    // FTS search (multi-app)
    func searchMetas(_ ftsQuery: String,
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     captureKinds: [CaptureKind]? = nil,
                     audioSourceKinds: [AudioSourceKind]? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) throws -> [SnapshotMeta] {
        // Delegate to unified implementation using a single MATCH part
        let rows = try searchUnified(ftsParts: [ftsQuery],
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     captureKinds: captureKinds,
                                     audioSourceKinds: audioSourceKinds,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        return rows.map(makeSnapshotMeta)
    }

    // FTS search with multiple MATCH parts AND-combined at SQL level
    func searchMetas(_ ftsParts: [String],
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     captureKinds: [CaptureKind]? = nil,
                     audioSourceKinds: [AudioSourceKind]? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) throws -> [SnapshotMeta] {
        guard !ftsParts.isEmpty else { return [] }
        let rows = try searchUnified(ftsParts: ftsParts,
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     captureKinds: captureKinds,
                                     audioSourceKinds: audioSourceKinds,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        return rows.map(makeSnapshotMeta)
    }

    // Paged search with raw text content for snippet UI (multi-app)
    func searchWithContent(_ ftsQuery: String,
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil,
                           captureKinds: [CaptureKind]? = nil,
                           audioSourceKinds: [AudioSourceKind]? = nil,
                           limit: Int = 50,
                           offset: Int = 0) throws -> [SearchResult] {
        let rows = try searchUnified(ftsParts: [ftsQuery],
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     captureKinds: captureKinds,
                                     audioSourceKinds: audioSourceKinds,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        let results = rows.map { makeSearchResult(from: $0) }
        return try hydrateSearchResultContents(results)
    }

    // FTS search with multiple MATCH parts AND-combined at SQL level (with content)
    func searchWithContent(_ ftsParts: [String],
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil,
                           captureKinds: [CaptureKind]? = nil,
                           audioSourceKinds: [AudioSourceKind]? = nil,
                           limit: Int = 50,
                           offset: Int = 0) throws -> [SearchResult] {
        guard !ftsParts.isEmpty else { return [] }
        let rows = try searchUnified(ftsParts: ftsParts,
                                     appBundleIds: appBundleIds,
                                     startMs: startMs,
                                     endMs: endMs,
                                     captureKinds: captureKinds,
                                     audioSourceKinds: audioSourceKinds,
                                     limit: limit,
                                     offset: offset,
                                     includeContent: false)
        let results = rows.map { makeSearchResult(from: $0) }
        return try hydrateSearchResultContents(results)
    }

    /// Snapshot rows for the given ids, in the given order (missing ids are skipped).
    func searchResults(snapshotIds: [Int64]) throws -> [SearchResult] {
        guard !snapshotIds.isEmpty else { return [] }
        let byId = try onReadQueueSync { db -> [Int64: SearchResult] in
            let placeholders = Array(repeating: "?", count: snapshotIds.count).joined(separator: ",")
            let sql = """
            SELECT s.id, s.started_at_ms, s.ended_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, s.capture_kind, s.source_kind, s.audio_asset_id, a.duration_ms
            FROM ts_snapshot s
            LEFT JOIN ts_audio_asset a ON a.id = s.audio_asset_id
            WHERE s.id IN (\(placeholders));
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            for (index, id) in snapshotIds.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), id)
            }
            var rows: [Int64: SearchResult] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = makeSearchRowUnified(from: stmt) {
                    rows[row.id] = makeSearchResult(from: row)
                }
            }
            return rows
        }
        return snapshotIds.compactMap { byId[$0] }
    }

    /// Core FTS search used by both `searchMetas` and `searchWithContent` wrappers.
    private func searchUnified(ftsParts: [String],
                               appBundleIds: [String]?,
                               startMs: Int64?,
                               endMs: Int64?,
                               captureKinds: [CaptureKind]?,
                               audioSourceKinds: [AudioSourceKind]?,
                               limit: Int,
                               offset: Int,
                               includeContent: Bool) throws -> [SearchRowUnified] {
        try onReadQueueSync { db in
            guard !ftsParts.isEmpty else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.ended_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, s.capture_kind, s.source_kind, s.audio_asset_id, a.duration_ms
            FROM ts_snapshot s
            LEFT JOIN ts_audio_asset a ON a.id = s.audio_asset_id
            WHERE 1=1
            """
            // Each part is an OR-group of variants; parts are AND-combined. With only the new
            // index, all parts go into a single FTS expression so FTS5 intersects the postings.
            // Legacy tables (and text_ref_id rows only they cover) are consulted per part until
            // the backfill drops them.
            let legacy = Self.legacyTextTablesExist(db: db)
            let matchBinds: [String]
            if legacy {
                let match = Self.textMatchSubquery(legacyTablesExist: true)
                let legacyRefMatch = "SELECT snapshot_id FROM ts_text_chunk WHERE ts_text_chunk MATCH ? UNION SELECT rowid FROM ts_text WHERE ts_text MATCH ?"
                for _ in ftsParts {
                    sql += " AND (s.id IN (\(match.sql)) OR s.text_ref_id IN (\(legacyRefMatch)))"
                }
                matchBinds = ftsParts.flatMap { Array(repeating: $0, count: match.bindsPerPart + 2) }
            } else {
                sql += " AND s.id IN (\(Self.textMatchSubquery(legacyTablesExist: false).sql))"
                matchBinds = [ftsParts.map { "(\($0))" }.joined(separator: " AND ")]
            }
            if let s = startMs { sql += " AND s.started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND s.started_at_ms <= \(e)" }
            if let ids = appBundleIds, !ids.isEmpty {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                sql += " AND s.app_bundle_id IN (\(placeholders))"
            }
            appendCaptureFilterSQL(to: &sql,
                                   alias: "s",
                                   captureKinds: captureKinds,
                                   audioSourceKinds: audioSourceKinds)
            sql += " ORDER BY s.started_at_ms DESC LIMIT ? OFFSET ?;"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            for value in matchBinds {
                sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT); idx += 1
            }
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            }
            bindCaptureFilters(stmt: stmt,
                               index: &idx,
                               captureKinds: captureKinds,
                               audioSourceKinds: audioSourceKinds)
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SearchRowUnified] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = makeSearchRowUnified(from: stmt) {
                    rows.append(SearchRowUnified(id: row.id,
                                                 startedAtMs: row.startedAtMs,
                                                 endedAtMs: row.endedAtMs,
                                                 path: row.path,
                                                 appBundleId: row.appBundleId,
                                                 appName: row.appName,
                                                 thumbPath: row.thumbPath,
                                                 captureKind: row.captureKind,
                                                 audioSourceKind: row.audioSourceKind,
                                                 audioAssetId: row.audioAssetId,
                                                 audioDurationMs: row.audioDurationMs,
                                                 content: includeContent ? "" : nil))
                }
            }
            return rows
        }
    }

}
