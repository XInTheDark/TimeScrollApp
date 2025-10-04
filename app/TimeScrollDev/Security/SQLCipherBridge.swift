import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

final class SQLCipherBridge {
    static let shared = SQLCipherBridge()
    private init() {}

    func openWithUnwrappedKeySilently() {
        // If vault is enabled, do NOT fall back to plaintext open.
        let d = UserDefaults.standard
        let vaultOn = (d.object(forKey: "settings.vaultEnabled") != nil) ? d.bool(forKey: "settings.vaultEnabled") : false
        if let key = try? KeyStore.shared.unwrapDbKey() {
            _ = try? DB.shared.openWithSqlcipher(key: key)
            // Log runtime cipher version for verification
            DB.shared.logCipherVersion()
            verifyHeader()
            return
        }
        // No key unwrapped
        if vaultOn {
            // Leave DB closed; callers should treat this as locked/not available
            return
        }
        // Vault disabled: allow normal (plaintext) open
        _ = try? DB.shared.openIfNeeded()
    }

    func close() { DB.shared.close() }

    // MARK: - Migration (plaintext -> encrypted)
    func migratePlaintextIfNeeded(withKey key: Data) {
        let (url, exists) = dbURL()
        guard exists else { return }
        // Detect if file appears to be plaintext SQLite by header magic
        if isLikelyPlaintextSQLite(url: url) {
            do {
                try migrateFile(at: url, key: key)
                print("[SQLCipher] Migration complete: db is now encrypted")
                verifyHeader()
            } catch {
                print("[SQLCipher] Migration failed: \(error)")
            }
        } else {
            // Already encrypted (or not a plain SQLite header); nothing to do
        }
    }

    // MARK: - Migration (encrypted -> plaintext)
    func migrateEncryptedToPlaintextIfNeeded(withKey key: Data) {
        let (url, exists) = dbURL()
        guard exists else { return }
        // If it looks like plaintext, nothing to do
        if isLikelyPlaintextSQLite(url: url) { return }
        do {
            try migrateEncryptedFileToPlaintext(at: url, key: key)
            print("[SQLCipher] Reverse migration complete: db is now plaintext")
        } catch {
            print("[SQLCipher] Reverse migration failed: \(error)")
        }
    }

    private func dbURL() -> (URL, Bool) {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TimeScroll", isDirectory: true)
        let url = dir.appendingPathComponent("db.sqlite")
        return (url, fm.fileExists(atPath: url.path))
    }

    private func isLikelyPlaintextSQLite(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let head = try? fh.read(upToCount: 16) ?? Data()
        if let head = head, let s = String(data: head, encoding: .utf8) {
            return s.hasPrefix("SQLite format 3")
        }
        return false
    }

    private func migrateFile(at url: URL, key: Data) throws {
        // Create a new encrypted DB and export from the plaintext DB into it
        let encURL = url.deletingLastPathComponent().appendingPathComponent("db.sqlite.enc.tmp")
        _ = try? FileManager.default.removeItem(at: encURL)

        var encDB: OpaquePointer?
        guard sqlite3_open(encURL.path, &encDB) == SQLITE_OK, let enc = encDB else {
            throw NSError(domain: "TS.SQLCipher", code: -10, userInfo: [NSLocalizedDescriptionKey: "Open enc DB failed"])
        }
        defer { sqlite3_close(enc) }

        let hex = key.map { String(format: "%02x", $0) }.joined()
        // Apply key and cipher settings on the encrypted DB connection
        let keySQL = "PRAGMA key = \"x'\(hex)'\";"
        _ = sqlite3_exec(enc, keySQL, nil, nil, nil)
        _ = sqlite3_exec(enc, "PRAGMA cipher_compatibility = 4;", nil, nil, nil)
        _ = sqlite3_exec(enc, "PRAGMA kdf_iter = 256000;", nil, nil, nil)
        _ = sqlite3_exec(enc, "PRAGMA cipher_page_size = 4096;", nil, nil, nil)
        _ = sqlite3_exec(enc, "PRAGMA cipher_hmac_algorithm = HMAC_SHA256;", nil, nil, nil)
        _ = sqlite3_exec(enc, "PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA256;", nil, nil, nil)

        // Attach the plaintext DB to this connection with empty key
        let plainPath = url.path.replacingOccurrences(of: "'", with: "''")
        let attachPlain = "ATTACH DATABASE '\(plainPath)' AS plaintext KEY '';"
        guard sqlite3_exec(enc, attachPlain, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.SQLCipher", code: -11, userInfo: [NSLocalizedDescriptionKey: "ATTACH plaintext failed"])
        }

        // Export from plaintext (attached) into main (encrypted)
        guard sqlite3_exec(enc, "SELECT sqlcipher_export('main','plaintext');", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.SQLCipher", code: -12, userInfo: [NSLocalizedDescriptionKey: "sqlcipher_export failed"])
        }

        // Preserve user_version
        _ = sqlite3_exec(enc, "PRAGMA main.user_version = plaintext.user_version;", nil, nil, nil)
        _ = sqlite3_exec(enc, "DETACH DATABASE plaintext;", nil, nil, nil)

        // Replace original with encrypted copy
        sqlite3_close(enc)
        let _ = try FileManager.default.replaceItemAt(url, withItemAt: encURL)

        // Best-effort cleanup of any existing WAL/SHM from prior plaintext DB
        let baseDir = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent
        let wal = baseDir.appendingPathComponent(baseName + "-wal")
        let shm = baseDir.appendingPathComponent(baseName + "-shm")
        _ = try? FileManager.default.removeItem(at: wal)
        _ = try? FileManager.default.removeItem(at: shm)
    }

    private func migrateEncryptedFileToPlaintext(at url: URL, key: Data) throws {
        // Create a new plaintext DB and export from the encrypted DB into it
        let plainURL = url.deletingLastPathComponent().appendingPathComponent("db.sqlite.plain.tmp")
        _ = try? FileManager.default.removeItem(at: plainURL)

        var plainDB: OpaquePointer?
        guard sqlite3_open(plainURL.path, &plainDB) == SQLITE_OK, let plain = plainDB else {
            throw NSError(domain: "TS.SQLCipher", code: -20, userInfo: [NSLocalizedDescriptionKey: "Open plaintext DB failed"])
        }
        defer { sqlite3_close(plain) }

        // Attach the encrypted DB to this connection with provided key
        let hex = key.map { String(format: "%02x", $0) }.joined()
        let encPath = url.path.replacingOccurrences(of: "'", with: "''")
        let attachEnc = "ATTACH DATABASE '\(encPath)' AS cipher KEY \"x'\(hex)'\";"
        guard sqlite3_exec(plain, attachEnc, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.SQLCipher", code: -21, userInfo: [NSLocalizedDescriptionKey: "ATTACH cipher failed"])
        }

        // Apply cipher settings on the attached database to ensure compatibility
        _ = sqlite3_exec(plain, "PRAGMA cipher.cipher_compatibility = 4;", nil, nil, nil)
        _ = sqlite3_exec(plain, "PRAGMA cipher.kdf_iter = 256000;", nil, nil, nil)
        _ = sqlite3_exec(plain, "PRAGMA cipher.cipher_page_size = 4096;", nil, nil, nil)
        _ = sqlite3_exec(plain, "PRAGMA cipher.cipher_hmac_algorithm = HMAC_SHA256;", nil, nil, nil)
        _ = sqlite3_exec(plain, "PRAGMA cipher.cipher_kdf_algorithm = PBKDF2_HMAC_SHA256;", nil, nil, nil)

        // Export from attached encrypted (cipher) into main (plaintext)
        guard sqlite3_exec(plain, "SELECT sqlcipher_export('main','cipher');", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "TS.SQLCipher", code: -22, userInfo: [NSLocalizedDescriptionKey: "sqlcipher_export reverse failed"])
        }

        // Preserve user_version
        _ = sqlite3_exec(plain, "PRAGMA main.user_version = cipher.user_version;", nil, nil, nil)
        _ = sqlite3_exec(plain, "DETACH DATABASE cipher;", nil, nil, nil)

        // Close before replacing
        sqlite3_close(plain)

        // Replace original encrypted DB with plaintext copy
        let _ = try FileManager.default.replaceItemAt(url, withItemAt: plainURL)

        // Best-effort cleanup of any existing WAL/SHM from prior SQLCipher DB
        let baseDir = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent
        let wal = baseDir.appendingPathComponent(baseName + "-wal")
        let shm = baseDir.appendingPathComponent(baseName + "-shm")
        _ = try? FileManager.default.removeItem(at: wal)
        _ = try? FileManager.default.removeItem(at: shm)
    }

    // Post-open / post-migration verification helper
    private func verifyHeader() {
        let (url, exists) = dbURL()
        guard exists else { return }
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            let head = try? fh.read(upToCount: 16) ?? Data()
            if let head = head, let s = String(data: head, encoding: .utf8), s.hasPrefix("SQLite format 3") {
                print("[SQLCipher][WARN] Database header still plaintext magic. This implies SQLCipher isn't active (likely linking system libsqlite3). Ensure 'import SQLCipher' is used and the SQLCipher package product is linked.")
            } else {
                print("[SQLCipher] Header check passed (no plaintext magic).")
            }
        }
    }
}
