import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// The one SQLCipher configuration every encrypted connection uses. Every connection to the
/// vault database (writer, reader, migrations) must key and configure through here: a
/// connection that reads a page with other settings fails with "file is not a database".
enum SQLCipherSettings {
  static let pragmas = [
    "PRAGMA cipher_compatibility = 4;",
    "PRAGMA kdf_iter = 256000;",
    "PRAGMA cipher_page_size = 4096;",
    "PRAGMA cipher_hmac_algorithm = HMAC_SHA256;",
    "PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA256;"
  ]

  /// Keys the main database of `db` and applies the settings. Call before anything reads a page.
  static func apply(key: Data, to db: OpaquePointer) throws {
    // Without SQLCipher linked, PRAGMA key is silently ignored and data would stay plaintext.
    guard cipherVersion(db) != nil else {
      throw NSError(domain: "TS.SQLCipher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Encryption support is unavailable."])
    }
    try exec(db, "PRAGMA key = \"x'\(hex(key))'\";")
    for pragma in pragmas { try exec(db, pragma) }
  }

  /// Steps a schema read, which fails unless the key and settings match the file.
  static func verifyReadable(_ db: OpaquePointer) throws {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW else {
      throw error(db, "The database could not be read with the vault key")
    }
  }

  /// The linked SQLCipher version: library capability only, never proof a connection is keyed.
  static func cipherVersion(_ db: OpaquePointer) -> String? {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
  }

  static func hex(_ key: Data) -> String {
    key.map { String(format: "%02x", $0) }.joined()
  }

  static func exec(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db, "SQL failed") }
  }

  static func error(_ db: OpaquePointer?, _ context: String) -> NSError {
    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    return NSError(domain: "TS.SQLCipher", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(context): \(message)"])
  }
}
