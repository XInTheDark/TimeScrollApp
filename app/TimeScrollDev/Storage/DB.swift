import Foundation
import CoreGraphics
import Vision
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    private(set) var db: OpaquePointer?
    private(set) var dbURL: URL?
    private let queue = DispatchQueue(label: "com.timescroll.db")
    private let queueKey = DispatchSpecificKey<Bool>()

    func onQueueSync<T>(_ block: () throws -> T) rethrows -> T {
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
        let vaultOn = (StoragePaths.sharedObject(forKey: "settings.vaultEnabled") != nil)
            ? StoragePaths.sharedBool(forKey: "settings.vaultEnabled")
            : false
        let unlocked = StoragePaths.sharedBool(forKey: "vault.isUnlocked")
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
        if let u = dbURL { fputs("[DB] opened at \(u.path)\n", stderr) }
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
                fputs("[SQLCipher] Opened with cipher_version=\(v)\n", stderr)
            } else {
                fputs("[SQLCipher][WARN] cipher_version unavailable; this likely means the system SQLite (unencrypted) was linked. The database is NOT encrypted.\n", stderr)
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
                    fputs("[SQLCipher] cipher_version=\(String(cString: c))\n", stderr)
                } else {
                    fputs("[SQLCipher] cipher_version=(unavailable)\n", stderr)
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
            app_name TEXT,
            text_ref_id INTEGER,
            text_store_id INTEGER
        );
        -- L2-normalized sentence embeddings for semantic search
        CREATE TABLE IF NOT EXISTS ts_embedding (
            snapshot_id INTEGER NOT NULL,
            dim INTEGER NOT NULL,
            vec BLOB NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            provider TEXT NOT NULL DEFAULT 'apple-nl',
            model TEXT NOT NULL DEFAULT ''
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
        CREATE TABLE IF NOT EXISTS ts_text_store (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sha256 TEXT NOT NULL UNIQUE,
            codec TEXT NOT NULL,
            original_bytes INTEGER NOT NULL,
            data BLOB NOT NULL
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK { throw NSError(domain: "TS.DB", code: 2) }
        // Create FTS table if missing
        let fts = "CREATE VIRTUAL TABLE IF NOT EXISTS ts_text USING fts5(content, tokenize='unicode61 remove_diacritics 2');"
        _ = sqlite3_exec(db, fts, nil, nil, nil)
        let chunkFTS = "CREATE VIRTUAL TABLE IF NOT EXISTS ts_text_chunk USING fts5(snapshot_id UNINDEXED, chunk_index UNINDEXED, content, tokenize='unicode61 remove_diacritics 2');"
        _ = sqlite3_exec(db, chunkFTS, nil, nil, nil)
        // Indices for faster joins and scans
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_snapshot_started_at_ms ON ts_snapshot(started_at_ms DESC);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_snapshot_app_bundle_started_at_ms ON ts_snapshot(app_bundle_id, started_at_ms DESC);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_snapshot_text_store_id ON ts_snapshot(text_store_id);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_ocr_boxes_snapshot_id ON ts_ocr_boxes(snapshot_id);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_ts_embedding_identity ON ts_embedding(snapshot_id, provider, model);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_dim ON ts_embedding(dim);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_model ON ts_embedding(model);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_provider_model ON ts_embedding(provider, model);", nil, nil, nil)
    }

    // Best-effort on-disk header verification; if the first 16 bytes still show the plain SQLite header
    // after opening with a key and creating schema, we warn so the user knows encryption isn't active.
    private func verifyEncryptedHeader() {
        guard let url = dbURL else { return }
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            let head = try? fh.read(upToCount: 16) ?? Data()
            if let head = head, let s = String(data: head, encoding: .utf8), s.hasPrefix("SQLite format 3") {
                fputs("[SQLCipher][WARN] On-disk header still plaintext. This indicates SQLCipher is not actually applied. Ensure the SQLCipher package is imported (import SQLCipher) and system libsqlite3 is not used.\n", stderr)
            } else {
                fputs("[SQLCipher] On-disk header does not match plaintext magic; looks encrypted.\n", stderr)
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
            if !columnExists("ts_snapshot", column: "text_ref_id") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN text_ref_id INTEGER;", nil, nil, nil)
            }
            if !columnExists("ts_snapshot", column: "text_store_id") {
                _ = sqlite3_exec(db, "ALTER TABLE ts_snapshot ADD COLUMN text_store_id INTEGER;", nil, nil, nil)
            }
        }
        if !tableExists("ts_ocr_boxes") {
            let sql = "CREATE TABLE ts_ocr_boxes (snapshot_id INTEGER NOT NULL, text TEXT NOT NULL, x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL);"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_ocr_boxes_snapshot_id ON ts_ocr_boxes(snapshot_id);", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_snapshot_app_bundle_started_at_ms ON ts_snapshot(app_bundle_id, started_at_ms DESC);", nil, nil, nil)
        if !tableExists("ts_text") {
            let fts = "CREATE VIRTUAL TABLE ts_text USING fts5(content, tokenize='unicode61 remove_diacritics 2');"
            _ = sqlite3_exec(db, fts, nil, nil, nil)
        }
        if !tableExists("ts_text_store") {
            let sql = "CREATE TABLE ts_text_store (id INTEGER PRIMARY KEY AUTOINCREMENT, sha256 TEXT NOT NULL UNIQUE, codec TEXT NOT NULL, original_bytes INTEGER NOT NULL, data BLOB NOT NULL);"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
        if !tableExists("ts_text_chunk") {
            let sql = "CREATE VIRTUAL TABLE ts_text_chunk USING fts5(snapshot_id UNINDEXED, chunk_index UNINDEXED, content, tokenize='unicode61 remove_diacritics 2');"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_snapshot_text_store_id ON ts_snapshot(text_store_id);", nil, nil, nil)
        if !tableExists("ts_embedding") {
            let sql = "CREATE TABLE ts_embedding (snapshot_id INTEGER NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL, updated_at_ms INTEGER NOT NULL, provider TEXT NOT NULL DEFAULT 'apple-nl', model TEXT NOT NULL DEFAULT '');"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_ts_embedding_identity ON ts_embedding(snapshot_id, provider, model);", nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_dim ON ts_embedding(dim);", nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_model ON ts_embedding(model);", nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_provider_model ON ts_embedding(provider, model);", nil, nil, nil)
        }
        // Migrate existing ts_embedding to add provider column
        if tableExists("ts_embedding") && !columnExists("ts_embedding", column: "provider") {
            _ = sqlite3_exec(db, "ALTER TABLE ts_embedding ADD COLUMN provider TEXT NOT NULL DEFAULT 'apple-nl';", nil, nil, nil)
        }
        // Add model column if missing
        if tableExists("ts_embedding") && !columnExists("ts_embedding", column: "model") {
            _ = sqlite3_exec(db, "ALTER TABLE ts_embedding ADD COLUMN model TEXT NOT NULL DEFAULT '';", nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_model ON ts_embedding(model);", nil, nil, nil)
        }
        if tableExists("ts_embedding") {
            migrateEmbeddingIdentityIfNeeded(db: db)
            _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_ts_embedding_identity ON ts_embedding(snapshot_id, provider, model);", nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_ts_embedding_provider_model ON ts_embedding(provider, model);", nil, nil, nil)
        }
    }

    private func migrateEmbeddingIdentityIfNeeded(db: OpaquePointer) {
        guard embeddingTableNeedsIdentityMigration(db: db) else { return }
        _ = sqlite3_exec(db, "ALTER TABLE ts_embedding RENAME TO ts_embedding_legacy;", nil, nil, nil)
        let create = """
        CREATE TABLE ts_embedding (
            snapshot_id INTEGER NOT NULL,
            dim INTEGER NOT NULL,
            vec BLOB NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            provider TEXT NOT NULL DEFAULT 'apple-nl',
            model TEXT NOT NULL DEFAULT ''
        );
        """
        _ = sqlite3_exec(db, create, nil, nil, nil)
        _ = sqlite3_exec(db, "INSERT INTO ts_embedding(snapshot_id, dim, vec, updated_at_ms, provider, model) SELECT snapshot_id, dim, vec, updated_at_ms, provider, model FROM ts_embedding_legacy;", nil, nil, nil)
        _ = sqlite3_exec(db, "DROP TABLE ts_embedding_legacy;", nil, nil, nil)
    }

    private func embeddingTableNeedsIdentityMigration(db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(ts_embedding);", -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let isPrimaryKey = sqlite3_column_int(stmt, 5) > 0
            if name == "snapshot_id" && isPrimaryKey {
                return true
            }
        }
        return false
    }
}
