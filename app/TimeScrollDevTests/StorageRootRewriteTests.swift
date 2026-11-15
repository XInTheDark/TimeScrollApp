import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// A storage move repoints every stored media path, and a rewrite that cannot run yet (locked
/// vault, closed database) stays owed until it succeeds.
struct StorageRootRewriteTests {
  private func defaults() -> UserDefaults {
    let name = "StorageRootRewriteTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  @Test func pendingMovesApplyOldestFirstAndClear() {
    let d = defaults()
    StorageRootRewrite.record(oldRoot: "/a", newRoot: "/b", defaults: d)
    StorageRootRewrite.record(oldRoot: "/b", newRoot: "/c", defaults: d)
    var applied: [StorageRootRewrite.Move] = []
    #expect(StorageRootRewrite.applyPending(defaults: d) { applied.append($0) })
    #expect(applied.map(\.newRoot) == ["/b", "/c"])
    #expect(StorageRootRewrite.pending(defaults: d).isEmpty)
  }

  @Test func failedRewriteStaysPending() {
    let d = defaults()
    StorageRootRewrite.record(oldRoot: "/a", newRoot: "/b", defaults: d)
    StorageRootRewrite.record(oldRoot: "/b", newRoot: "/c", defaults: d)
    var calls = 0
    let ok = StorageRootRewrite.applyPending(defaults: d) { move in
      calls += 1
      if move.newRoot == "/c" { throw NSError(domain: "test", code: 1) }
    }
    #expect(!ok)
    #expect(calls == 2)
    #expect(StorageRootRewrite.pending(defaults: d) == [.init(oldRoot: "/b", newRoot: "/c")])
  }

  @Test func relocateMatchesWholeFolderNamesOnly() {
    let move = StorageRootRewrite.Move(oldRoot: "/Volumes/A/TimeScroll", newRoot: "/Users/me/TS")
    #expect(StorageRootRewrite.relocate(URL(fileURLWithPath: "/Volumes/A/TimeScroll/Videos/seg.tse"), move).path == "/Users/me/TS/Videos/seg.tse")
    #expect(StorageRootRewrite.relocate(URL(fileURLWithPath: "/Volumes/A/TimeScroll2/x.tse"), move).path == "/Volumes/A/TimeScroll2/x.tse")
  }

  @Test func journalsFollowTheMove() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let record = VaultFileMigration.Record(snapshotID: 4, timestamp: 9,
                                           source: URL(fileURLWithPath: "/old/Snapshots/a.heic"),
                                           destination: URL(fileURLWithPath: "/old/Snapshots/a.X.tse"),
                                           digest: "d", mime: "image/heic")
    let journal = dir.appendingPathComponent("j.json")
    try JSONEncoder().encode(record).write(to: journal)
    try StorageRootRewrite.rewriteJournals(.init(oldRoot: "/old", newRoot: "/new"), in: dir)
    let moved = try JSONDecoder().decode(VaultFileMigration.Record.self, from: Data(contentsOf: journal))
    #expect(moved.source.path == "/new/Snapshots/a.heic")
    #expect(moved.destination.path == "/new/Snapshots/a.X.tse")
    #expect(moved.digest == "d" && moved.snapshotID == 4)
  }

  @Test func databaseRewriteCoversSnapshotsPostersAndAudio() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rootmove-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    let db = try #require(handle)
    defer { sqlite3_close(db) }
    try SQLCipherSettings.exec(db, """
      CREATE TABLE ts_snapshot (id INTEGER PRIMARY KEY, path TEXT NOT NULL, thumb_path TEXT);
      CREATE TABLE ts_audio_asset (id INTEGER PRIMARY KEY, path TEXT NOT NULL);
      INSERT INTO ts_snapshot(path, thumb_path) VALUES ('/old/Videos/seg.tse', '/old/Snapshots/p.tse');
      INSERT INTO ts_snapshot(path, thumb_path) VALUES ('/old2/Videos/seg.tse', NULL);
      INSERT INTO ts_audio_asset(path) VALUES ('/old/Audio/a.tse');
      """)
    let changed = try DB.rewriteMediaPaths(db: db, oldRoot: "/old", newRoot: "/new")
    #expect(changed == 3)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    sqlite3_prepare_v2(db, "SELECT path FROM ts_snapshot UNION ALL SELECT thumb_path FROM ts_snapshot WHERE thumb_path IS NOT NULL UNION ALL SELECT path FROM ts_audio_asset;", -1, &stmt, nil)
    var paths: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW { paths.append(String(cString: sqlite3_column_text(stmt, 0))) }
    #expect(paths.sorted() == ["/new/Audio/a.tse", "/new/Snapshots/p.tse", "/new/Videos/seg.tse", "/old2/Videos/seg.tse"])
  }
}
