import Foundation
import CoreGraphics
import Vision
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Compact metadata row for timeline/search without N+1 lookups.
struct SnapshotMeta: Identifiable, Hashable {
    let id: Int64
    let startedAtMs: Int64
    let path: String
    let appBundleId: String?
    let appName: String?
    let thumbPath: String?
}

// Search result row including raw text content for snippet building in UI
struct SearchResult: Identifiable, Hashable {
    let id: Int64
    let startedAtMs: Int64
    let path: String
    let appBundleId: String?
    let appName: String?
    let thumbPath: String?
    let content: String
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
        try StoragePaths.withSecurityScope {
        // If vault is enabled but not unlocked, block DB access to avoid leaking metadata
        let d = UserDefaults.standard
        let vaultOn = (d.object(forKey: "settings.vaultEnabled") != nil) ? d.bool(forKey: "settings.vaultEnabled") : false
        let unlocked = d.bool(forKey: "vault.isUnlocked")
        // When vault is enabled & unlocked the caller should have already opened via SQLCipherBridge.
        // We defensively refuse plaintext open in that case to avoid accidental downgrade.
        if vaultOn && unlocked { throw NSError(domain: "TS.DB", code: -101, userInfo: [NSLocalizedDescriptionKey: "Encrypted vault active; use SQLCipherBridge.openWithUnwrappedKeySilently() first"]) }
        if vaultOn && !unlocked { throw NSError(domain: "TS.DB", code: -100, userInfo: [NSLocalizedDescriptionKey: "Vault locked"]) }
        // Resolve storage root (user-selected or default) and ensure it exists
        try StoragePaths.ensureRootExists()
        let url = StoragePaths.dbURL()
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
    }

    // Open using SQLCipher key. If SQLCipher is not linked yet, the PRAGMA statements will be no-ops.
    func openWithSqlcipher(key: Data) throws {
        try StoragePaths.withSecurityScope {
        if db != nil {
            // If already open, verify it's SQLCipher; if not, close and reopen encrypted
            var test: OpaquePointer?
            if let existing = db, sqlite3_prepare_v2(existing, "PRAGMA cipher_version;", -1, &test, nil) == SQLITE_OK {
                if sqlite3_step(test) == SQLITE_ROW {
                    sqlite3_finalize(test)
                    return // already encrypted
                }
            }
            sqlite3_finalize(test)
            close()
        }
        try StoragePaths.ensureRootExists()
        let url = StoragePaths.dbURL()
        dbURL = url
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK { throw NSError(domain: "TS.DB", code: 1) }
        self.db = handle
        // Provide key in hex for PRAGMA key = "x'..'" form
    let hex = key.map { String(format: "%02x", $0) }.joined()
    // Use proper hex key literal form: x'..'
    let keySQL = "PRAGMA key = \"x'\(hex)'\";"
    _ = sqlite3_exec(handle, keySQL, nil, nil, nil)
        // Ensure we are really running against a SQLCipher-enabled build. cipher_version should return a row.
        var verStmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "PRAGMA cipher_version;", -1, &verStmt, nil) == SQLITE_OK {
            if sqlite3_step(verStmt) == SQLITE_ROW, let c = sqlite3_column_text(verStmt, 0) {
                let v = String(cString: c)
                print("[SQLCipher] Opened with cipher_version=\(v)")
            } else {
                print("[SQLCipher][WARN] cipher_version unavailable; this likely means the system SQLite (unencrypted) was linked. The database is NOT encrypted.")
            }
        }
        sqlite3_finalize(verStmt)
        _ = sqlite3_exec(handle, "PRAGMA cipher_compatibility = 4;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA kdf_iter = 256000;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA cipher_page_size = 4096;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA cipher_hmac_algorithm = HMAC_SHA256;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA256;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    _ = sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA temp_store=MEMORY;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA cache_size=-2000;", nil, nil, nil)
    // Immediately checkpoint and truncate WAL to avoid stale WAL pages causing HMAC issues
    _ = sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        // Verify key by a simple query; if it fails, close and throw
        var testStmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master;", -1, &testStmt, nil) != SQLITE_OK {
            sqlite3_finalize(testStmt)
            sqlite3_close(handle)
            self.db = nil
            throw NSError(domain: "TS.DB", code: -50, userInfo: [NSLocalizedDescriptionKey: "SQLCipher key verification failed"])
        }
        sqlite3_finalize(testStmt)
        try createSchema()
        try migrateIfNeeded()
        // After schema ensures at least one write, verify the on-disk header is no longer the plaintext SQLite magic.
        verifyEncryptedHeader()
        }
    }

    func close() {
        if let handle = db { sqlite3_close(handle) }
        db = nil
    }

    // Log SQLCipher version if available; useful to verify encryption at runtime
    func logCipherVersion() {
        onQueueSync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                    print("[SQLCipher] cipher_version=\(String(cString: c))")
                } else {
                    print("[SQLCipher] cipher_version=(unavailable)")
                }
            }
        }
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
        -- L2-normalized sentence embeddings for semantic search
        CREATE TABLE IF NOT EXISTS ts_embedding (
            snapshot_id INTEGER PRIMARY KEY,
            dim INTEGER NOT NULL,
            vec BLOB NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            provider TEXT NOT NULL DEFAULT 'apple-nl'
        );
        CREATE TABLE IF NOT EXISTS ts_ocr_boxes (
            snapshot_id INTEGER NOT NULL,
            text TEXT NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL,
            w REAL NOT NULL,
            h REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ts_usage_session (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_s REAL NOT NULL,
            end_s REAL
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK { throw NSError(domain: "TS.DB", code: 2) }
        // Create FTS table if missing
        let fts = "CREATE VIRTUAL TABLE IF NOT EXISTS ts_text USING fts5(content, tokenize='unicode61 remove_diacritics 2');"
        _ = sqlite3_exec(db, fts, nil, nil, nil)
        // Indices for faster joins and scans
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_snapshot_started_at_ms ON ts_snapshot(started_at_ms DESC);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_dim ON ts_embedding(dim);", nil, nil, nil)
    }

    // Best-effort on-disk header verification; if the first 16 bytes still show the plain SQLite header
    // after opening with a key and creating schema, we warn so the user knows encryption isn't active.
    private func verifyEncryptedHeader() {
        guard let url = dbURL else { return }
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            let head = try? fh.read(upToCount: 16) ?? Data()
            if let head = head, let s = String(data: head, encoding: .utf8), s.hasPrefix("SQLite format 3") {
                print("[SQLCipher][WARN] On-disk header still plaintext. This indicates SQLCipher is not actually applied. Ensure the SQLCipher package is imported (import SQLCipher) and system libsqlite3 is not used.")
            } else {
                print("[SQLCipher] On-disk header does not match plaintext magic; looks encrypted.")
            }
        }
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
        if !tableExists("ts_embedding") {
            let sql = "CREATE TABLE ts_embedding (snapshot_id INTEGER PRIMARY KEY, dim INTEGER NOT NULL, vec BLOB NOT NULL, updated_at_ms INTEGER NOT NULL, provider TEXT NOT NULL DEFAULT 'apple-nl');"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_dim ON ts_embedding(dim);", nil, nil, nil)
        }
        // Migrate existing ts_embedding to add provider column
        if tableExists("ts_embedding") && !columnExists("ts_embedding", column: "provider") {
            _ = sqlite3_exec(db, "ALTER TABLE ts_embedding ADD COLUMN provider TEXT NOT NULL DEFAULT 'apple-nl';", nil, nil, nil)
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

    // MARK: - Embeddings

    func upsertEmbedding(snapshotId: Int64, dim: Int, vec: [Float], provider: String) throws {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT INTO ts_embedding(snapshot_id, dim, vec, updated_at_ms, provider) VALUES(?, ?, ?, ?, ?)\n                       ON CONFLICT(snapshot_id) DO UPDATE SET dim=excluded.dim, vec=excluded.vec, updated_at_ms=excluded.updated_at_ms, provider=excluded.provider;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, snapshotId)
            sqlite3_bind_int(stmt, 2, Int32(dim))
            // Store as raw Float32 contiguous data
            let data = vec.withUnsafeBufferPointer { Data(buffer: $0) }
            data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            sqlite3_bind_int64(stmt, 4, nowMs)
            sqlite3_bind_text(stmt, 5, provider, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    struct EmbeddingCandidate: Hashable {
        let result: SearchResult
        let vector: [Float]
        let dim: Int
    }

    func embeddingCandidates(appBundleIds: [String]? = nil,
                              startMs: Int64? = nil,
                              endMs: Int64? = nil,
                              limit: Int = 2000,
                              offset: Int = 0,
                              requireDim: Int,
                              requireProvider: String) throws -> [EmbeddingCandidate] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, t.content, e.vec, e.dim
            FROM ts_embedding e
            JOIN ts_snapshot s ON s.id = e.snapshot_id
            LEFT JOIN ts_text t ON t.rowid = s.id
            WHERE e.dim = ? AND e.provider = ?
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
            sqlite3_bind_int(stmt, idx, Int32(requireDim)); idx += 1
            sqlite3_bind_text(stmt, idx, requireProvider, -1, SQLITE_TRANSIENT); idx += 1
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [EmbeddingCandidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let content = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                // vec blob
                let blobPtr = sqlite3_column_blob(stmt, 7)
                let blobLen = Int(sqlite3_column_bytes(stmt, 7))
                let dim = Int(sqlite3_column_int(stmt, 8))
                var vector: [Float] = []
                if let ptr = blobPtr, blobLen >= dim * MemoryLayout<Float>.size {
                    let count = blobLen / MemoryLayout<Float>.size
                    vector = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
                }
                let res = SearchResult(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name, thumbPath: thumb, content: content)
                rows.append(EmbeddingCandidate(result: res, vector: vector, dim: dim))
            }
            return rows
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
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
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

    // FTS search (multi-app)
    func searchMetas(_ ftsQuery: String,
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) throws -> [SnapshotMeta] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path
            FROM ts_text t
            JOIN ts_snapshot s ON s.id = t.rowid
            WHERE t.content MATCH ?
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
            sqlite3_bind_text(stmt, idx, ftsQuery, -1, SQLITE_TRANSIENT); idx += 1
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
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

    // FTS search with multiple MATCH parts AND-combined at SQL level
    func searchMetas(_ ftsParts: [String],
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) throws -> [SnapshotMeta] {
        try onQueueSync {
            guard !ftsParts.isEmpty else { return [] }
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path
            FROM ts_text t
            JOIN ts_snapshot s ON s.id = t.rowid
            WHERE 1=1
            """
            // Add one MATCH per part to preserve per-token OR-group semantics
            for _ in ftsParts { sql += " AND t.content MATCH ?" }
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
            for p in ftsParts { sqlite3_bind_text(stmt, idx, p, -1, SQLITE_TRANSIENT); idx += 1 }
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
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
            try openIfNeeded(); guard let db = db else { return nil }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
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
            if let p = thumbPath { sqlite3_bind_text(stmt, 1, p, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_int64(stmt, 2, rowId)
            _ = sqlite3_step(stmt)
        }
    }

    // Return (id, thumbPath) for rows with posters in the range [startMs, endMs]
    func rowsWithThumbs(startMs: Int64, endMs: Int64) throws -> [(Int64, String)] {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return [] }
            let sql = "SELECT id, thumb_path FROM ts_snapshot WHERE started_at_ms >= ? AND started_at_ms <= ? AND thumb_path IS NOT NULL;"
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
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

    // Paged search with raw text content for snippet UI (multi-app)
    func searchWithContent(_ ftsQuery: String,
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil,
                           limit: Int = 50,
                           offset: Int = 0) throws -> [SearchResult] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, t.content
            FROM ts_text t
            JOIN ts_snapshot s ON s.id = t.rowid
            WHERE t.content MATCH ?
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
            sqlite3_bind_text(stmt, idx, ftsQuery, -1, SQLITE_TRANSIENT); idx += 1
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let content = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                rows.append(SearchResult(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name, thumbPath: thumb, content: content))
            }
            return rows
        }
    }

    // FTS search with multiple MATCH parts AND-combined at SQL level (with content)
    func searchWithContent(_ ftsParts: [String],
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil,
                           limit: Int = 50,
                           offset: Int = 0) throws -> [SearchResult] {
        try onQueueSync {
            guard !ftsParts.isEmpty else { return [] }
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, t.content
            FROM ts_text t
            JOIN ts_snapshot s ON s.id = t.rowid
            WHERE 1=1
            """
            for _ in ftsParts { sql += " AND t.content MATCH ?" }
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
            for p in ftsParts { sqlite3_bind_text(stmt, idx, p, -1, SQLITE_TRANSIENT); idx += 1 }
            if let ids = appBundleIds, !ids.isEmpty {
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let content = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                rows.append(SearchResult(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name, thumbPath: thumb, content: content))
            }
            return rows
        }
    }

    // Latest with content (for empty query) to show snippet-like previews consistently (multi-app)
    func latestWithContent(limit: Int = 50,
                           offset: Int = 0,
                           appBundleIds: [String]? = nil,
                           startMs: Int64? = nil,
                           endMs: Int64? = nil) throws -> [SearchResult] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var sql = """
            SELECT s.id, s.started_at_ms, s.path, s.app_bundle_id, s.app_name, s.thumb_path, t.content
            FROM ts_snapshot s
            LEFT JOIN ts_text t ON t.rowid = s.id
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
                for bid in ids { sqlite3_bind_text(stmt, idx, bid, -1, SQLITE_TRANSIENT); idx += 1 }
            }
            sqlite3_bind_int(stmt, idx, Int32(limit)); idx += 1
            sqlite3_bind_int(stmt, idx, Int32(offset))
            var rows: [SearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_int64(stmt, 1)
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let bid = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let thumb = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let content = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                rows.append(SearchResult(id: id, startedAtMs: ts, path: path, appBundleId: bid, appName: name, thumbPath: thumb, content: content))
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

    func snapshotCountSince(ms cutoffMs: Int64) throws -> Int {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ts_snapshot WHERE started_at_ms >= ?;", -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    // Best-effort accurate byte sums, deduped by path and
    // falling back to on-disk size when DB bytes are missing/zero (e.g., HEVC during open segments).
    func sumSnapshotBytesAll() throws -> Int64 {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            // Deduplicate by path; take max recorded bytes for that path.
            let sql = "SELECT path, MAX(COALESCE(bytes, 0)) AS b FROM ts_snapshot GROUP BY path;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            var total: Int64 = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let b = sqlite3_column_int64(stmt, 1)
                if b > 0 { total &+= b }
                else { total &+= fileSizeForSnapshotPath(path) }
            }
            return total
        }
    }

    func sumSnapshotBytesSince(ms cutoffMs: Int64) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            let sql = "SELECT path, MAX(COALESCE(bytes, 0)) AS b FROM ts_snapshot WHERE started_at_ms >= ? GROUP BY path;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            var total: Int64 = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let b = sqlite3_column_int64(stmt, 1)
                if b > 0 { total &+= b }
                else { total &+= fileSizeForSnapshotPath(path) }
            }
            return total
        }
    }

    private func fileSizeForSnapshotPath(_ path: String) -> Int64 {
        var size: Int64 = 0
        StoragePaths.withSecurityScope {
            let u = URL(fileURLWithPath: path)
            if let vals = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
                size = Int64(vals.fileSize ?? 0)
            } else if u.pathExtension.lowercased() == "tse" {
                let mov = u.deletingPathExtension().appendingPathExtension("mov")
                if let vals2 = try? mov.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals2.isRegularFile == true {
                    size = Int64(vals2.fileSize ?? 0)
                }
            }
        }
        return size
    }

    func avgSnapshotBytesAll() throws -> Int64 { try avgSnapshotBytes() }

    func avgSnapshotBytesSince(ms cutoffMs: Int64) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT AVG(bytes) FROM ts_snapshot WHERE started_at_ms >= ? AND bytes IS NOT NULL;", -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_int64(stmt, 0) }
            return 0
        }
    }

    // MARK: - Usage sessions
    func beginUsageSession(start: TimeInterval) throws -> Int64 {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { throw NSError(domain: "TS.DB", code: 800) }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT INTO ts_usage_session(start_s) VALUES(?);"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw NSError(domain: "TS.DB", code: 801) }
            sqlite3_bind_double(stmt, 1, start)
            if sqlite3_step(stmt) != SQLITE_DONE { throw NSError(domain: "TS.DB", code: 802) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func endUsageSession(id: Int64, end: TimeInterval) throws {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "UPDATE ts_usage_session SET end_s=? WHERE id=? AND end_s IS NULL;", -1, &stmt, nil) != SQLITE_OK { return }
            sqlite3_bind_double(stmt, 1, end)
            sqlite3_bind_int64(stmt, 2, id)
            _ = sqlite3_step(stmt)
        }
    }

    func totalUsageSeconds(now: TimeInterval) throws -> TimeInterval {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            // Fetch all sessions up to now and compute the union of intervals to avoid double counting
            let sql = "SELECT start_s, COALESCE(end_s, ?) AS end_s FROM ts_usage_session WHERE start_s <= ? ORDER BY start_s ASC;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_double(stmt, 2, now)

            var mergedStart: Double? = nil
            var mergedEnd: Double = 0
            var total: Double = 0

            while sqlite3_step(stmt) == SQLITE_ROW {
                let s = sqlite3_column_double(stmt, 0)
                let eRaw = sqlite3_column_double(stmt, 1)
                // Clamp any inverted rows defensively
                let e = max(eRaw, s)
                if mergedStart == nil {
                    mergedStart = s; mergedEnd = e
                    continue
                }
                if s > mergedEnd { // disjoint
                    total += max(0, mergedEnd - (mergedStart ?? mergedEnd))
                    mergedStart = s; mergedEnd = e
                } else { // overlap or touch
                    if e > mergedEnd { mergedEnd = e }
                }
            }
            if let ms = mergedStart {
                total += max(0, mergedEnd - ms)
            }
            return total
        }
    }

    func usageSecondsSince(cutoff: TimeInterval, now: TimeInterval) throws -> TimeInterval {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return 0 }
            let lo = min(cutoff, now)
            let hi = max(cutoff, now)
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            // Fetch sessions overlapping [cutoff, now] and compute the union of clamped intervals
            let sql = "SELECT start_s, end_s FROM ts_usage_session WHERE start_s <= ? AND COALESCE(end_s, ?) >= ? ORDER BY start_s ASC;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return 0 }
            sqlite3_bind_double(stmt, 1, hi)
            sqlite3_bind_double(stmt, 2, hi)
            sqlite3_bind_double(stmt, 3, lo)

            var mergedStart: Double? = nil
            var mergedEnd: Double = 0
            var total: Double = 0

            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawS = sqlite3_column_double(stmt, 0)
                let rawE = (sqlite3_column_type(stmt, 1) != SQLITE_NULL) ? sqlite3_column_double(stmt, 1) : hi
                // Clamp to [lo, hi] and ensure non-negative interval
                let s = max(lo, min(rawS, hi))
                let e = max(s, min(rawE, hi))

                if mergedStart == nil {
                    mergedStart = s; mergedEnd = e
                    continue
                }
                if s > mergedEnd { // disjoint
                    total += max(0, mergedEnd - (mergedStart ?? mergedEnd))
                    mergedStart = s; mergedEnd = e
                } else { // overlap or touch
                    if e > mergedEnd { mergedEnd = e }
                }
            }
            if let ms = mergedStart { total += max(0, mergedEnd - ms) }
            return total
        }
    }

    func finalizeStaleOpenUsageSessions(maxOpenSeconds: TimeInterval, now: TimeInterval) {
        _ = try? onQueueSync {
            try openIfNeeded(); guard let db = db else { return }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT id, start_s FROM ts_usage_session WHERE end_s IS NULL;", -1, &stmt, nil) != SQLITE_OK { return }
            var stale: [(Int64, Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let start = sqlite3_column_double(stmt, 1)
                if now - start > maxOpenSeconds {
                    stale.append((id, start))
                }
            }
            sqlite3_finalize(stmt); stmt = nil
            if stale.isEmpty { return }
            for (id, start) in stale {
                var upd: OpaquePointer?; defer { sqlite3_finalize(upd) }
                if sqlite3_prepare_v2(db, "UPDATE ts_usage_session SET end_s=? WHERE id=? AND end_s IS NULL;", -1, &upd, nil) == SQLITE_OK {
                    let clampEnd = start + maxOpenSeconds
                    sqlite3_bind_double(upd, 1, clampEnd)
                    sqlite3_bind_int64(upd, 2, id)
                    _ = sqlite3_step(upd)
                }
            }
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

    func listPlaintextSnapshots(limit: Int = 10_000) throws -> [SnapshotRow] {
        try onQueueSync {
            try openIfNeeded()
            guard let db = db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, started_at_ms, path FROM ts_snapshot WHERE path NOT LIKE '%.tse' ORDER BY started_at_ms ASC LIMIT ?;"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return [] }
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

    func updateSnapshotPath(oldPath: String, newPath: String, bytes: Int64?, format: String?) {
        _ = try? onQueueSync {
            try openIfNeeded()
            guard let db = db else { return }
            var sets: [String] = ["path=?"]
            if bytes != nil { sets.append("bytes=?") }
            if format != nil { sets.append("format=?") }
            let sql = "UPDATE ts_snapshot SET \(sets.joined(separator: ", ")) WHERE path=?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
            var idx: Int32 = 1
            sqlite3_bind_text(stmt, idx, newPath, -1, SQLITE_TRANSIENT); idx += 1
            if let v = bytes { sqlite3_bind_int64(stmt, idx, v); idx += 1 }
            if let v = format { sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT); idx += 1 }
            sqlite3_bind_text(stmt, idx, oldPath, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
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
        var pathsToHandle: [String] = []
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT path FROM ts_snapshot WHERE started_at_ms < ?;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    pathsToHandle.append(String(cString: cstr))
                }
            }
        }
        // Move each path to backup if enabled; otherwise delete.
        let fm = FileManager.default
        for p in pathsToHandle {
            let srcURL = URL(fileURLWithPath: p)
            let archived = StoragePaths.archiveSnapshotToBackupIfEnabled(srcURL)
            if !archived { _ = try? fm.removeItem(at: srcURL) }
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

    // Delete rows older than a specific cutoff, optionally skipping on-disk deletions.
    func purgeRowsOlderThan(cutoffMs cutoff: Int64, deleteFiles: Bool) throws {
        try onQueueSync {
            try openIfNeeded(); guard let db = db else { return }
            var pathsToHandle: [String] = []
            if deleteFiles {
                var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
                if sqlite3_prepare_v2(db, "SELECT path FROM ts_snapshot WHERE started_at_ms < ?;", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, cutoff)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let cstr = sqlite3_column_text(stmt, 0) { pathsToHandle.append(String(cString: cstr)) }
                    }
                }
                let fm = FileManager.default
                for p in pathsToHandle {
                    let srcURL = URL(fileURLWithPath: p)
                    let archived = StoragePaths.archiveSnapshotToBackupIfEnabled(srcURL)
                    if !archived { _ = try? fm.removeItem(at: srcURL) }
                }
            }
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
