import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// Database conversion when the vault is turned on or off: verified copies, the production
/// cipher settings, and an untouched original on every failure.
struct SQLCipherFileMigratorTests {
  private let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

  private func makePlaintextDB() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlcipher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("db.sqlite")
    try withDB(url, key: nil) { db in
      try SQLCipherSettings.exec(db, "PRAGMA journal_mode=WAL;")
      try SQLCipherSettings.exec(db, """
        CREATE TABLE ts_snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL);
        CREATE VIRTUAL TABLE ts_text_index USING fts5(content);
        PRAGMA user_version = 7;
        """)
      for i in 0..<250 {
        try SQLCipherSettings.exec(db, "INSERT INTO ts_snapshot(path) VALUES ('/r/seg-\(i).tse');")
        try SQLCipherSettings.exec(db, "INSERT INTO ts_text_index(content) VALUES ('secret text \(i)');")
      }
    }
    return url
  }

  private func withDB<T>(_ url: URL, key: Data?, _ body: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else { throw NSError(domain: "test", code: 1) }
    defer { sqlite3_close(db) }
    if let key { try SQLCipherSettings.apply(key: key, to: db) }
    return try body(db)
  }

  private func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
      throw SQLCipherSettings.error(db, sql)
    }
    return sqlite3_column_int64(stmt, 0)
  }

  private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  @Test func encryptThenDecryptRoundTripsDataAndUserVersion() throws {
    let url = try makePlaintextDB()
    defer { cleanup(url) }
    try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key)
    #expect(!SQLCipherFileMigrator.isPlaintextSQLite(url))
    let encrypted = try withDB(url, key: key) { db in
      [try scalar(db, "SELECT count(*) FROM ts_snapshot;"),
       try scalar(db, "SELECT count(*) FROM ts_text_index WHERE ts_text_index MATCH 'secret';"),
       try scalar(db, "PRAGMA user_version;")]
    }
    #expect(encrypted == [250, 250, 7])
    // Without the key the file is unreadable.
    #expect(throws: (any Error).self) { try withDB(url, key: nil) { try scalar($0, "SELECT count(*) FROM ts_snapshot;") } }

    try SQLCipherFileMigrator.decrypt(encryptedAt: url, key: key)
    #expect(SQLCipherFileMigrator.isPlaintextSQLite(url))
    let decrypted = try withDB(url, key: nil) { db in
      [try scalar(db, "SELECT count(*) FROM ts_snapshot;"), try scalar(db, "PRAGMA user_version;")]
    }
    #expect(decrypted == [250, 7])
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(!leftovers.contains { $0.hasSuffix(".tmp") })
  }

  @Test func emptyDatabaseRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlcipher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("db.sqlite")
    defer { cleanup(url) }
    try withDB(url, key: nil) { try SQLCipherSettings.exec($0, "CREATE TABLE t (x);") }
    try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key)
    try SQLCipherFileMigrator.decrypt(encryptedAt: url, key: key)
    #expect(try withDB(url, key: nil) { try scalar($0, "SELECT count(*) FROM t;") } == 0)
  }

  @Test func insufficientSpaceLeavesPlaintextUntouched() throws {
    let url = try makePlaintextDB()
    defer { cleanup(url) }
    let before = try Data(contentsOf: url)
    #expect(throws: (any Error).self) {
      try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key, capacity: { _ in 1_024 })
    }
    #expect(try Data(contentsOf: url) == before)
    #expect(SQLCipherFileMigrator.isPlaintextSQLite(url))
  }

  @Test func insufficientSpaceLeavesEncryptedUntouched() throws {
    let url = try makePlaintextDB()
    defer { cleanup(url) }
    try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key)
    let before = try Data(contentsOf: url)
    #expect(throws: (any Error).self) {
      try SQLCipherFileMigrator.decrypt(encryptedAt: url, key: key, capacity: { _ in 0 })
    }
    #expect(try Data(contentsOf: url) == before)
  }

  @Test func wrongKeyFailsWithoutChangingTheFile() throws {
    let url = try makePlaintextDB()
    defer { cleanup(url) }
    try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key)
    let before = try Data(contentsOf: url)
    #expect(throws: (any Error).self) {
      try SQLCipherFileMigrator.decrypt(encryptedAt: url, key: Data(repeating: 9, count: 32))
    }
    #expect(try Data(contentsOf: url) == before)
    #expect(try withDB(url, key: key) { try scalar($0, "SELECT count(*) FROM ts_snapshot;") } == 250)
  }

  @Test func corruptSourceFailsWithoutReplacingIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlcipher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("db.sqlite")
    defer { cleanup(url) }
    let garbage = Data("SQLite format 3\u{0}".utf8) + Data(repeating: 0xAB, count: 8_192)
    try garbage.write(to: url)
    #expect(throws: (any Error).self) { try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key) }
    #expect(try Data(contentsOf: url) == garbage)
  }

  /// The previous reverse migration attached the encrypted file before applying its settings;
  /// SQLCipher reads the schema on ATTACH with its SHA512 defaults and fails.
  @Test func attachingBeforeSettingsCannotReadProductionDatabase() throws {
    let url = try makePlaintextDB()
    defer { cleanup(url) }
    try SQLCipherFileMigrator.encrypt(plaintextAt: url, key: key)
    let other = url.deletingLastPathComponent().appendingPathComponent("plain.sqlite")
    let attach = "ATTACH DATABASE '\(url.path)' AS cipher KEY \"x'\(SQLCipherSettings.hex(key))'\";"
    let rc = try withDB(other, key: nil) { sqlite3_exec($0, attach, nil, nil, nil) }
    #expect(rc != SQLITE_OK)
  }
}
