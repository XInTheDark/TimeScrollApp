import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Legacy search hit struct removed; timeline uses SnapshotMeta.

// Compact metadata row for timeline/search without N+1 lookups.
struct SnapshotMeta: Identifiable, Hashable {
    let id: Int64
    let startedAtMs: Int64
    let path: String
    let appBundleId: String?
    let appName: String?
}

final class DB {
    static let shared = DB()
    private init() { queue.setSpecific(key: queueKey, value: true) }

    private var db: OpaquePointer?
    private(set) var dbURL: URL?
    private let queue = DispatchQueue(label: "com.timescroll.db")
    private let queueKey = DispatchSpecificKey<Bool>()

    private func onQueueSync<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return try block()
        }
        return try queue.sync { try block() }
    }

    struct OCRBoxRow {
        let text: String
        let rect: CGRect
    }

    func openIfNeeded() throws {
        if db != nil { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TimeScroll", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("db.sqlite")
        dbURL = url
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK { throw NSError(domain: "TS.DB", code: 1) }
        self.db = handle
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA temp_store=MEMORY;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA cache_size=-2000;", nil, nil, nil)
        try createSchema()
        try migrateIfNeeded()
    }

    private func createSchema() throws {
        guard let db = db else { return }
        let schema = """
        CREATE TABLE IF NOT EXISTS ts_snapshot (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at_ms INTEGER NOT NULL,
            path TEXT NOT NULL,
            app_bundle_id TEXT,
            app_name TEXT
        );
        CREATE TABLE IF NOT EXISTS ts_ocr_boxes (
            snapshot_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL,
            w REAL NOT NULL,
            h REAL NOT NULL
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK { throw NSError(domain: "TS.DB", code: 2) }
        // Create FTS table if missing
        let fts = "CREATE VIRTUAL TABLE IF NOT EXISTS ts_text USING fts5(content, tokenize='unicode61 remove_diacritics 2');"
        _ = sqlite3_exec(db, fts, nil, nil, nil)
    }

    private func tableExists(_ name: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?;", -1, &stmt, nil) != SQLITE_OK { return false }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnExists(_ table: String, column: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) != SQLITE_OK { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1) {
                if String(cString: cstr) == column { return true }
            }
        }
        return false
    }

    private func migrateIfNeeded() throws {
        guard let db = db else { return }
        if tableExists("ts_snapshot") {
            if !columnExists("ts_snapshot", column: "app_bundle_id") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN app_bundle_id TEXT;", nil, nil, nil)
            }
            if !columnExists("ts_snapshot", column: "app_name") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN app_name TEXT;", nil, nil, nil)
            }
            // Storage/metadata columns
            if !columnExists("ts_snapshot", column: "bytes") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN bytes INTEGER;", nil, nil, nil)
            }
            if !columnExists("ts_snapshot", column: "width") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN width INTEGER;", nil, nil, nil)
            }
            if !columnExists("ts_snapshot", column: "height") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN height INTEGER;", nil, nil, nil)
            }
            if !columnExists("ts_snapshot", column: "format") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN format TEXT;", nil, nil, nil)
            }
            if !columnExists("ts_snapshot", column: "hash64") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN hash64 INTEGER;", nil, nil, nil)
            }
            if !columnExists("ts_snapshot", column: "thumb_path") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN thumb_path TEXT;", nil, nil, nil)
            }
        }
        if !tableExists("ts_ocr_boxes") {
            let sql = "CREATE TABLE ts_ocr_boxes (snapshot_id INTEGER NOT NULL, text TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL);"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
        if !tableExists("ts_text") {
            let fts = "CREATE VIRTUAL TABLE ts_text USING fts5(content, tokenize='unicode61 remove_diacritics 2');"
            _ = sqlite3_exec(db, fts, nil, nil, nil)
        }
    }

    func insertSnapshot(
        startedAtMs: Int64,
        path: String,
        text: String,
        appBundleId: String?,
        appName: String?,
        boxes: [OCRLine] = [],
        bytes: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        format: String? = nil,
        hash64: Int64? = nil,
        thumbPath: String? = nil
    ) throws -> Int64 {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { throw NSError(domain: "TS.DB", code: 3) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT INTO ts_snapshot(started_at_ms, path, app_bundle_id, app_name, bytes, width, height, format, hash64, thumb_path)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw NSError(domain: "TS.DB", code: 4)
        }
        sqlite3_bind_int64(stmt, 1, startedAtMs)
        sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
        if let b = appBundleId { sqlite3_bind_text(stmt, 3, b, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        if let n = appName { sqlite3_bind_text(stmt, 4, n, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
        if let v = bytes { sqlite3_bind_int64(stmt, 5, v) } else { sqlite3_bind_null(stmt, 5) }
        if let v = width { sqlite3_bind_int(stmt, 6, Int32(v)) } else { sqlite3_bind_null(stmt, 6) }
        if let v = height { sqlite3_bind_int(stmt, 7, Int32(v)) } else { sqlite3_bind_null(stmt, 7) }
        if let v = format { sqlite3_bind_text(stmt, 8, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
        if let v = hash64 { sqlite3_bind_int64(stmt, 9, v) } else { sqlite3_bind_null(stmt, 9) }
        if let v = thumbPath { sqlite3_bind_text(stmt, 10, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 10) }
        if sqlite3_step(stmt) != SQLITE_DONE { throw NSError(domain: "TS.DB", code: 5) }
        let rowId = sqlite3_last_insert_rowid(db)
        var tstmt: OpaquePointer?
        defer { sqlite3_finalize(tstmt) }
        if sqlite3_prepare_v2(db, "INSERT INTO ts_text(rowid, content) VALUES(?, ?);", -1, &tstmt, nil) != SQLITE_OK {
            throw NSError(domain: "TS.DB", code: 6)
        }
        sqlite3_bind_int64(tstmt, 1, rowId)
        sqlite3_bind_text(tstmt, 2, text, -1, SQLITE_TRANSIENT)
        if sqlite3_step(tstmt) != SQLITE_DONE { throw NSError(domain: "TS.DB", code: 7) }

        if !boxes.isEmpty {
            var bstmt: OpaquePointer?
            defer { sqlite3_finalize(bstmt) }
            if sqlite3_prepare_v2(db, "INSERT INTO ts_ocr_boxes(snapshot_id, text, x, y, w, h) VALUES(?, ?, ?, ?, ?, ?);", -1, &bstmt, nil) != SQLITE_OK {
                return rowId
            }
            for box in boxes {
                sqlite3_bind_int64(bstmt, 1, rowId)
                sqlite3_bind_text(bstmt, 2, box.text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(bstmt, 3, Double(box.box.origin.x))
                sqlite3_bind_double(bstmt, 4, Double(box.box.origin.y))
                sqlite3_bind_double(bstmt, 5, Double(box.box.size.width))
                sqlite3_bind_double(bstmt, 6, Double(box.box.size.height))
                _ = sqlite3_step(bstmt)
                sqlite3_reset(bstmt)
            }
        }
        return rowId
        }
    }

    func avgSnapshotBytes() throws -> Int64 {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT AVG(bytes) FROM ts_snapshot WHERE bytes IS NOT NULL;", -1, &stmt, nil) != SQLITE_OK { return 0 }
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
        }
    }

    func pathsOlderThan(cutoffMs: Int64) throws -> [String] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT path FROM ts_snapshot WHERE started_at_ms < ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            var paths: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    paths.append(String(cString: c))
                }
            }
            return paths
        }
    }

    func updateSnapshotMeta(path: String, bytes: Int64?, width: Int?, height: Int?, format: String?) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var sets: [String] = []
            if bytes != nil { sets.append("bytes=?") }
            if width != nil { sets.append("width=?") }
            if height != nil { sets.append("height=?") }
            if format != nil { sets.append("format=?") }
            guard !sets.isEmpty else { return }
            let sql = "UPDATE ts_snapshot SET \(sets.joined(separator: ", ")) WHERE path=?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
            var idx: Int32 = 1
            if let v = bytes { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            if let v = width { sqlite3_bind_int(stmt, idx, Int32(v)); idx += 1 }
            if let v = height { sqlite3_bind_int(stmt, idx, Int32(v)); idx += 1 }
            if let v = format { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_text(stmt, idx, path, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    func updateFTS(rowId: Int64, content: String) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "UPDATE ts_text SET content=? WHERE rowid=?;", -1, &stmt, nil) != SQLITE_OK {
                throw NSError(domain: "TS.DB", code: 100)
            }
            sqlite3_bind_text(stmt, 1, content, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, rowId)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw NSError(domain: "TS.DB", code: 101)
            }
        }
    }

    func replaceBoxes(snapshotId: Int64, boxes: [OCRLine]) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }

            var del: OpaquePointer?
            defer { sqlite3_finalize(del) }
            if sqlite3_prepare_v2(db, "DELETE FROM ts_ocr_boxes WHERE snapshot_id=?;", -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_int64(del, 1, snapshotId)
                _ = sqlite3_step(del)
            }

            guard !boxes.isEmpty else { return }

            var ins: OpaquePointer?
            defer { sqlite3_finalize(ins) }
            if sqlite3_prepare_v2(db, "INSERT INTO ts_ocr_boxes(snapshot_id, text, x, y, w, h) VALUES(?, ?, ?, ?, ?, ?);", -1, &ins, nil) != SQLITE_OK {
                return
            }
            for b in boxes {
                sqlite3_bind_int64(ins, 1, snapshotId)
                sqlite3_bind_text(ins, 2, b.text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(ins, 3, Double(b.box.origin.x))
                sqlite3_bind_double(ins, 4, Double(b.box.origin.y))
                sqlite3_bind_double(ins, 5, Double(b.box.size.width))
                sqlite3_bind_double(ins, 6, Double(b.box.size.height))
                _ = sqlite3_step(ins)
                sqlite3_reset(ins)
            }
        }
    }

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

    // Batched meta fetch for timeline/search views.
    func latestMetas(limit: Int = 1000,
                     offset: Int = 0,
                     appBundleId: String? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil) throws -> [SnapshotMeta] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT id, started_at_ms, path, app_bundle_id, app_name
            FROM ts_snapshot
            WHERE 1=1
            """
            if let s = startMs { sql += " AND started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND started_at_ms <= \(e)" }
            if appBundleId != nil { sql += " AND app_bundle_id = ?" }
            sql += " ORDER BY started_at_ms DESC LIMIT ? OFFSET ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            if let bid = appBundleId { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SnapshotMeta] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                rows.append(SnapshotMeta(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name))
            }
            return rows
        }
    }

    func searchMetas(_ ftsQuery: String,
                     appBundleId: String? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) throws -> [SnapshotMeta] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name
            FROM ts_text t
            JOIN ts_snapshot s ON s.id = t.rowid
            WHERE t.content MATCH ?
            """
            if let s = startMs { sql += " AND s.started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND s.started_at_ms <= \(e)" }
            if appBundleId != nil { sql += " AND s.app_bundle_id = ?" }
            sql += " ORDER BY s.started_at_ms DESC LIMIT ? OFFSET ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            sqlite3_bind_text(stmt, idx, ftsQuery, -1, SQLITE_TRANSIENT); idx += 1
            if let bid = appBundleId { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SnapshotMeta] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                rows.append(SnapshotMeta(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name))
            }
            return rows
        }
    }

    // Old FTS search with snippet removed; use searchMetas instead.

    enum BoxMatch {
        case equals
        case prefix
        case contains
    }

    func boxes(for snapshotId: Int64, matching query: String?, match: BoxMatch = .contains) throws -> [CGRect] {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return [] }
        var sql = "SELECT x,y,w,h FROM ts_ocr_boxes WHERE snapshot_id=?"
        if let q = query, !q.isEmpty {
            switch match {
            case .equals:
                sql += " AND text = ? COLLATE NOCASE"
            case .prefix, .contains:
                sql += " AND text LIKE ? COLLATE NOCASE"
            }
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
        sqlite3_bind_int64(stmt, 1, snapshotId)
        if let q = query, !q.isEmpty {
            switch match {
            case .equals:
                sqlite3_bind_text(stmt, 2, q, -1, SQLITE_TRANSIENT)
            case .prefix:
                let pat = "\(q)%"
                sqlite3_bind_text(stmt, 2, pat, -1, SQLITE_TRANSIENT)
            case .contains:
                let pat = "%\(q)%"
                sqlite3_bind_text(stmt, 2, pat, -1, SQLITE_TRANSIENT)
            }
        }
        var rects: [CGRect] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let x = sqlite3_column_double(stmt, 0)
            let y = sqlite3_column_double(stmt, 1)
            let w = sqlite3_column_double(stmt, 2)
            let h = sqlite3_column_double(stmt, 3)
            rects.append(CGRect(x: x, y: y, width: w, height: h))
        }
        return rects
        }
    }

    func boxesWithText(for snapshotId: Int64, matchingContains query: String?) throws -> [OCRBoxRow] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = "SELECT text,x,y,w,h FROM ts_ocr_boxes WHERE snapshot_id=?"
            if let q = query, !q.isEmpty {
                sql += " AND text LIKE ? COLLATE NOCASE"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
            sqlite3_bind_int64(stmt, 1, snapshotId)
            if let q = query, !q.isEmpty {
                let pat = "%\(q)%"
                sqlite3_bind_text(stmt, 2, pat, -1, SQLITE_TRANSIENT)
            }
            var rows: [OCRBoxRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(stmt, 0))
                let x = sqlite3_column_double(stmt, 1)
                let y = sqlite3_column_double(stmt, 2)
                let w = sqlite3_column_double(stmt, 3)
                let h = sqlite3_column_double(stmt, 4)
                rows.append(OCRBoxRow(text: text, rect: CGRect(x: x, y: y, width: w, height: h)))
            }
            return rows
        }
    }

    func snapshotCount() throws -> Int {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ts_snapshot;", -1, &stmt, nil) != SQLITE_OK { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func ftsCount() throws -> Int {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ts_text;", -1, &stmt, nil) != SQLITE_OK { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func findMetaByPath(_ path: String) throws -> (startedAtMs: Int64, appBundleId: String?)? {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT started_at_ms, app_bundle_id FROM ts_snapshot WHERE path=? LIMIT 1;", -1, &stmt, nil) != SQLITE_OK {
                return nil
            }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_int64(stmt, 0)
                let bptr = sqlite3_column_text(stmt, 1)
                let bid = bptr != nil ? String(cString: bptr!) : nil
                return (ts, bid)
            }
            return nil
        }
    }

    // Zero-based index of the snapshot within the current filtered ordering (DESC by time)
    func rankOfSnapshot(path: String, appBundleId: String? = nil, startMs: Int64? = nil, endMs: Int64? = nil) throws -> Int? {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return nil }
            // Fetch the target timestamp
            var tstmt: OpaquePointer?
            defer { sqlite3_finalize(tstmt) }
            if sqlite3_prepare_v2(db, "SELECT started_at_ms FROM ts_snapshot WHERE path=? LIMIT 1;", -1, &tstmt, nil) != SQLITE_OK {
                return nil
            }
            sqlite3_bind_text(tstmt, 1, path, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(tstmt) == SQLITE_ROW else { return nil }
            let targetTs = sqlite3_column_int64(tstmt, 0)

            var sql = "SELECT COUNT(*) FROM ts_snapshot WHERE 1=1"
            if let s = startMs { sql += " AND started_at_ms >= \(s)" }
            if let e = endMs { sql += " AND started_at_ms <= \(e)" }
            if appBundleId != nil { sql += " AND app_bundle_id = ?" }
            sql += " AND started_at_ms > ?;" // Items strictly newer than target

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return nil }
            var idx: Int32 = 1
            if let bid = appBundleId { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_int64(stmt, idx, targetTs)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    func distinctApps() throws -> [(bundleId: String, name: String)] {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // Use latest observed app_name per bundle id for better label accuracy
        let sql = """
        SELECT s.app_bundle_id,
               (
                   SELECT s2.app_name
                   FROM ts_snapshot s2
                   WHERE s2.app_bundle_id = s.app_bundle_id AND s2.app_name IS NOT NULL
                   ORDER BY s2.started_at_ms DESC
                   LIMIT 1
               ) AS name
        FROM ts_snapshot s
        WHERE s.app_bundle_id IS NOT NULL
        GROUP BY s.app_bundle_id
        ORDER BY COALESCE(name, s.app_bundle_id);
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return []
        }
        var result: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let bidC = sqlite3_column_text(stmt, 0) {
                let bid = String(cString: bidC)
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? bid
                result.append((bid, name))
            }
        }
        return result
        }
    }

    struct SnapshotRow: Identifiable, Hashable { let id: Int64; let startedAtMs: Int64; let path: String }

    func listSnapshots(limit: Int = 50) throws -> [SnapshotRow] {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT id, started_at_ms, path FROM ts_snapshot ORDER BY started_at_ms DESC LIMIT ?;", -1, &stmt, nil) != SQLITE_OK {
            return []
        }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [SnapshotRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_int64(stmt, 1)
            let path = String(cString: sqlite3_column_text(stmt, 2))
            rows.append(SnapshotRow(id: id, startedAtMs: ts, path: path))
        }
        return rows
        }
    }

    func clearFTS() throws {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return }
        _ = sqlite3_exec(db, "DELETE FROM ts_text;", nil, nil, nil)
        }
    }

    func purgeOlderThan(days: Int) throws {
        try onQueueSync {
        try openIfNeeded()
        guard let db = db else { return }
        let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
        // Collect file paths to delete before removing DB rows
        var stmt: OpaquePointer?
        var pathsToDelete: [String] = []
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT path FROM ts_snapshot WHERE started_at_ms < ?;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    pathsToDelete.append(String(cString: cstr))
                }
            }
        }

        // Delete files from disk (best-effort)
        let fm = FileManager.default
        for p in pathsToDelete {
            _ = try? fm.removeItem(atPath: p)
        }

        // Delete from FTS and primary tables by cutoff
        let sql = """
        DELETE FROM ts_text WHERE rowid IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
        DELETE FROM ts_ocr_boxes WHERE snapshot_id IN (SELECT id FROM ts_snapshot WHERE started_at_ms < \(cutoff));
        DELETE FROM ts_snapshot WHERE started_at_ms < \(cutoff);
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    func deleteSnapshot(id: Int64) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }

            // Lookup file path (and optional thumb path) before deleting rows
            var pStmt: OpaquePointer?
            defer { sqlite3_finalize(pStmt) }
            var pathToDelete: String? = nil
            var thumbToDelete: String? = nil
            if sqlite3_prepare_v2(db, "SELECT path, thumb_path FROM ts_snapshot WHERE id=? LIMIT 1;", -1, &pStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(pStmt, 1, id)
                if sqlite3_step(pStmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(pStmt, 0) { pathToDelete = String(cString: c) }
                    if let c2 = sqlite3_column_text(pStmt, 1) { thumbToDelete = String(cString: c2) }
                }
            }

            // Best-effort file deletions
            let fm = FileManager.default
            if let p = pathToDelete { _ = try? fm.removeItem(atPath: p) }
            if let t = thumbToDelete { _ = try? fm.removeItem(atPath: t) }

            // Delete associated text and boxes, then primary row
            _ = sqlite3_exec(db, "DELETE FROM ts_text WHERE rowid=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_ocr_boxes WHERE snapshot_id=\(id);", nil, nil, nil)
            _ = sqlite3_exec(db, "DELETE FROM ts_snapshot WHERE id=\(id);", nil, nil, nil)
        }
    }
}
