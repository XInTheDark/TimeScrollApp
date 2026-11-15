import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

final class SQLCipherBridge {
    static let shared = SQLCipherBridge()
    private init() {}

    /// Opens the database for the current vault state: encrypted with the in-memory key when
    /// the vault is enabled and unlocked, plaintext when the vault is off, closed otherwise.
    func openForCurrentVaultState() {
        let vaultOn = (StoragePaths.sharedObject(forKey: "settings.vaultEnabled") != nil)
            ? StoragePaths.sharedBool(forKey: "settings.vaultEnabled")
            : false
        if vaultOn {
            if let key = VaultKeys.shared.databaseKey {
                do { try openWithKey(key) } catch { fputs("[SQLCipher] open failed: \(error.localizedDescription)\n", stderr) }
            }
            return
        }
        _ = try? DB.shared.openIfNeeded()
    }

    /// Opens the encrypted database with `key`; throws when it cannot be opened and verified.
    func openWithKey(_ key: Data) throws {
        try DB.shared.openWithSqlcipher(key: key)
        DB.shared.logCipherVersion()
    }

    func close() { DB.shared.close() }

    /// True when a database file exists and no longer carries the plaintext SQLite header.
    func isDatabaseEncrypted() -> Bool {
        let (url, exists) = dbURL()
        guard exists else { return false }
        return StoragePaths.withSecurityScope { !SQLCipherFileMigrator.isPlaintextSQLite(url) }
    }

    /// Encrypts a plaintext database in place (no-op when there is none or it is already
    /// encrypted). Throws, leaving the plaintext file untouched, if any step fails.
    func migratePlaintextIfNeeded(withKey key: Data) throws {
        try StoragePaths.withSecurityScope {
            let (url, exists) = dbURL()
            guard exists, SQLCipherFileMigrator.isPlaintextSQLite(url) else { return }
            try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key)
            fputs("[SQLCipher] Migration complete: db is now encrypted\n", stderr)
        }
    }

    /// Decrypts the database in place (no-op when it is already plaintext). Throws, leaving the
    /// encrypted file untouched, if any step fails.
    func migrateEncryptedToPlaintextIfNeeded(withKey key: Data) throws {
        try StoragePaths.withSecurityScope {
            let (url, exists) = dbURL()
            guard exists, !SQLCipherFileMigrator.isPlaintextSQLite(url) else { return }
            try SQLCipherFileMigrator.decrypt(encryptedAt: url, key: key)
            fputs("[SQLCipher] Reverse migration complete: db is now plaintext\n", stderr)
        }
    }

    private func dbURL() -> (URL, Bool) {
        let url = StoragePaths.dbURL()
        let exists = FileManager.default.fileExists(atPath: url.path)
        return (url, exists)
    }
}
