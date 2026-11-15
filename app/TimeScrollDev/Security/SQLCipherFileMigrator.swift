import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Converts the database file between plaintext and SQLCipher. Each direction exports into a
/// temporary file, verifies the copy, and only then replaces the original, so any failure
/// throws and leaves the original untouched.
enum SQLCipherFileMigrator {
  /// Free bytes on the volume holding `url`, or nil when unknown.
  typealias CapacityProbe = (URL) -> Int64?

  static func availableCapacity(_ url: URL) -> Int64? {
    let values = try? url.deletingLastPathComponent()
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  static func isPlaintextSQLite(_ url: URL) -> Bool {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? fh.close() }
    guard let head = try? fh.read(upToCount: 16) else { return false }
    return head.starts(with: Data("SQLite format 3".utf8))
  }

  /// Encrypts the plaintext database at `url` in place.
  static func encrypt(plaintextAt url: URL, key: Data, capacity: CapacityProbe = availableCapacity) throws {
    try ensureSpace(for: url, capacity: capacity)
    try checkpoint(url, key: nil)
    let tmp = url.deletingLastPathComponent().appendingPathComponent("db.sqlite.enc.tmp")
    try? FileManager.default.removeItem(at: tmp)
    do {
      // The new encrypted file is main, keyed before any page exists; the source attaches as plaintext.
      try withConnection(tmp, key: key, verify: false) { enc in
        try SQLCipherSettings.exec(enc, "ATTACH DATABASE '\(quoted(url.path))' AS plaintext KEY '';")
        try SQLCipherSettings.exec(enc, "SELECT sqlcipher_export('main', 'plaintext');")
        let version = try userVersion(enc, schema: "plaintext")
        try SQLCipherSettings.exec(enc, "PRAGMA main.user_version = \(version);")
        try SQLCipherSettings.exec(enc, "DETACH DATABASE plaintext;")
      }
      guard !isPlaintextSQLite(tmp) else { throw failure("The encrypted copy still has a plaintext header.") }
      try verifyCopy(tmp, key: key, matches: url, sourceKey: nil)
      try replace(url, with: tmp)
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      throw error
    }
  }

  /// Decrypts the database at `url` in place.
  static func decrypt(encryptedAt url: URL, key: Data, capacity: CapacityProbe = availableCapacity) throws {
    try ensureSpace(for: url, capacity: capacity)
    try checkpoint(url, key: key)
    let tmp = url.deletingLastPathComponent().appendingPathComponent("db.sqlite.plain.tmp")
    try? FileManager.default.removeItem(at: tmp)
    do {
      // The encrypted source is main and keyed before its schema is read; ATTACH would read it
      // with SQLCipher's default (SHA512) settings and fail.
      try withConnection(url, key: key, verify: true) { cipher in
        try SQLCipherSettings.exec(cipher, "ATTACH DATABASE '\(quoted(tmp.path))' AS plaintext KEY '';")
        try SQLCipherSettings.exec(cipher, "SELECT sqlcipher_export('plaintext', 'main');")
        let version = try userVersion(cipher, schema: "main")
        try SQLCipherSettings.exec(cipher, "PRAGMA plaintext.user_version = \(version);")
        try SQLCipherSettings.exec(cipher, "DETACH DATABASE plaintext;")
      }
      guard isPlaintextSQLite(tmp) else { throw failure("The decrypted copy has no plaintext header.") }
      try verifyCopy(tmp, key: nil, matches: url, sourceKey: key)
      try replace(url, with: tmp)
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      throw error
    }
  }

  // MARK: - Steps

  /// The copy needs about the size of the database plus its WAL, with headroom.
  private static func ensureSpace(for url: URL, capacity: CapacityProbe) throws {
    let fm = FileManager.default
    let sizes = [url, sidecar(url, "-wal")].compactMap { (try? fm.attributesOfItem(atPath: $0.path)[.size]) as? Int64 }
    let needed = sizes.reduce(0, +) * 12 / 10 + 16 * 1024 * 1024
    if let free = capacity(url), free < needed {
      throw failure("There is not enough free disk space. About \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) is needed.")
    }
  }

  /// Folds the WAL into the main file, so the copy is complete and no stale WAL survives the swap.
  private static func checkpoint(_ url: URL, key: Data?) throws {
    try withConnection(url, key: key, verify: true) { db in
      try SQLCipherSettings.exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
    }
  }

  /// Confirms the copy passes an integrity check and holds the same tables and row counts.
  private static func verifyCopy(_ copy: URL, key: Data?, matches source: URL, sourceKey: Data?) throws {
    let copied = try withConnection(copy, key: key, verify: true) { db -> [String: Int64] in
      guard try scalarText(db, "PRAGMA quick_check;") == "ok" else { throw failure("The converted copy failed an integrity check.") }
      return try rowCounts(db)
    }
    let original = try withConnection(source, key: sourceKey, verify: true) { try rowCounts($0) }
    guard copied == original else { throw failure("The converted copy does not match the original.") }
  }

  private static func replace(_ url: URL, with tmp: URL) throws {
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    // Both sidecars belonged to the old file and were emptied by the checkpoint.
    try? FileManager.default.removeItem(at: sidecar(url, "-wal"))
    try? FileManager.default.removeItem(at: sidecar(url, "-shm"))
  }

  // MARK: - SQLite helpers

  private static func withConnection<T>(_ url: URL, key: Data?, verify: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = handle else {
      let error = SQLCipherSettings.error(handle, "Could not open \(url.lastPathComponent)")
      sqlite3_close(handle)
      throw error
    }
    defer { sqlite3_close(db) }
    if let key { try SQLCipherSettings.apply(key: key, to: db) }
    if verify { try SQLCipherSettings.verifyReadable(db) }
    return try body(db)
  }

  private static func rowCounts(_ db: OpaquePointer) throws -> [String: Int64] {
    // Virtual tables (FTS) are counted through their shadow tables.
    let names = try column(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name;")
    var counts: [String: Int64] = [:]
    for name in names {
      counts[name] = Int64(try scalarText(db, "SELECT count(*) FROM \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\";") ?? "") ?? -1
    }
    return counts
  }

  private static func userVersion(_ db: OpaquePointer, schema: String) throws -> Int64 {
    Int64(try scalarText(db, "PRAGMA \(schema).user_version;") ?? "0") ?? 0
  }

  private static func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String? {
    try column(db, sql).first
  }

  private static func column(_ db: OpaquePointer, _ sql: String) throws -> [String] {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLCipherSettings.error(db, "Query failed") }
    var out: [String] = []
    var rc = sqlite3_step(stmt)
    while rc == SQLITE_ROW {
      out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
      rc = sqlite3_step(stmt)
    }
    guard rc == SQLITE_DONE else { throw SQLCipherSettings.error(db, "Query failed") }
    return out
  }

  private static func sidecar(_ url: URL, _ suffix: String) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
  }

  private static func quoted(_ path: String) -> String { path.replacingOccurrences(of: "'", with: "''") }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "TS.SQLCipher", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
