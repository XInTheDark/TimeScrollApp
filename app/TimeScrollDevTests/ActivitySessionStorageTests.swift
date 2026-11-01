import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// The session SQL against a throwaway database file. It never touches `DB.shared`, so the user's
/// storage location and database are left alone.
@Suite(.serialized)
final class ActivitySessionStorageTests {
  private let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sessions-\(UUID().uuidString).sqlite")
  private var db: OpaquePointer!

  init() throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "test", code: 1) }
    db = handle
    exec("""
    CREATE TABLE ts_snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at_ms INTEGER NOT NULL, app_bundle_id TEXT, app_name TEXT,
                              text_ref_id INTEGER, text_store_id INTEGER, capture_kind TEXT NOT NULL DEFAULT 'screen');
    CREATE TABLE ts_text_store (id INTEGER PRIMARY KEY AUTOINCREMENT, sha256 TEXT NOT NULL UNIQUE, codec TEXT NOT NULL,
                                original_bytes INTEGER NOT NULL, data BLOB NOT NULL);
    """)
    DB.createSessionSketchTableIfNeeded(db: db)
    DB.createActivitySessionTablesIfNeeded(db: db)
  }

  deinit {
    sqlite3_close(db)
    try? FileManager.default.removeItem(at: url)
  }

  private func exec(_ sql: String) {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    #expect(result == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
  }

  private func addText(_ id: Int64) {
    exec("INSERT INTO ts_text_store(id, sha256, codec, original_bytes, data) VALUES(\(id), 'h\(id)', 'identity', 1, x'00');")
  }

  private func addSnapshot(_ id: Int64, at time: Int64, app: String? = "com.app", textStore: Int64? = nil,
                           textRef: Int64? = nil, kind: String = "screen") {
    let appSQL = app.map { "'\($0)'" } ?? "NULL"
    exec("""
    INSERT INTO ts_snapshot(id, started_at_ms, app_bundle_id, app_name, text_ref_id, text_store_id, capture_kind)
    VALUES(\(id), \(time), \(appSQL), \(appSQL), \(textRef.map(String.init) ?? "NULL"), \(textStore.map(String.init) ?? "NULL"), '\(kind)');
    """)
  }

  private func count(_ sql: String) -> Int {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  @Test func sampleRowsResolveSharedTextAndSketches() throws {
    addText(1); addText(2)
    DB.writeSessionSketch([3, 7, 9], textStoreId: 1, db: db)
    addSnapshot(1, at: 1_000, textStore: 1)
    addSnapshot(2, at: 2_000, textStore: nil, textRef: 1)   // identical text as snapshot 1
    addSnapshot(3, at: 3_000, textStore: 2)                 // text not sketched yet
    addSnapshot(4, at: 4_000, app: nil)                      // no text (OCR pending)
    addSnapshot(5, at: 4_500, kind: "audio")
    addSnapshot(6, at: 9_000, textStore: 1)                  // outside the range

    let rows = try DB.sessionSampleRows(fromMs: 0, toMs: 9_000, db: db)
    #expect(rows.map(\.snapshotId) == [1, 2, 3, 4])
    #expect(rows[0].sketch == [3, 7, 9])
    #expect(rows[1].textStoreId == 1)
    #expect(rows[1].sketch == [3, 7, 9])
    #expect(rows[2].textStoreId == 2)
    #expect(rows[2].sketch == nil)
    #expect(rows[3].textStoreId == nil)
    #expect(rows[3].appBundleId == nil)

    let fingerprint = try DB.sessionDayFingerprint(fromMs: 0, toMs: 9_000, db: db)
    #expect(fingerprint == SessionDayFingerprint(snapshotCount: 4, maxSnapshotId: 4, textCount: 3, sketchedCount: 2))
    #expect(!fingerprint.isComplete)
    // The provider derives the same fingerprint from the rows it read.
    #expect(SessionInput(rows: rows).fingerprint == fingerprint)
  }

  @Test func emptyRangeHasEmptyFingerprint() throws {
    #expect(try DB.sessionSampleRows(fromMs: 0, toMs: 100, db: db).isEmpty)
    #expect(try DB.sessionDayFingerprint(fromMs: 0, toMs: 100, db: db) == SessionDayFingerprint(snapshotCount: 0, maxSnapshotId: 0, textCount: 0, sketchedCount: 0))
  }

  @Test func wordlessTextStoresAnEmptySketchNotAMissingOne() throws {
    addText(1)
    DB.writeSessionSketch([], textStoreId: 1, db: db)
    addSnapshot(1, at: 1_000, textStore: 1)
    let rows = try DB.sessionSampleRows(fromMs: 0, toMs: 2_000, db: db)
    #expect(rows[0].sketch == [])
    #expect(try DB.sessionDayFingerprint(fromMs: 0, toMs: 2_000, db: db).isComplete)
  }

  @Test func storingAKnownTextKeepsItsSketch() throws {
    addText(1)
    DB.storeSessionSketchIfMissing(textStoreId: 1, content: "alpha beta gamma", db: db)
    let first = try DB.sessionSampleRows(fromMs: 0, toMs: 1, db: db)
    DB.storeSessionSketchIfMissing(textStoreId: 1, content: "completely different words", db: db)
    addSnapshot(1, at: 0, textStore: 1)
    #expect(first.isEmpty)
    #expect(try DB.sessionSampleRows(fromMs: 0, toMs: 1, db: db)[0].sketch == SessionTextSketch.make(from: "alpha beta gamma"))
  }

  @Test func unsketchedTextsComeNewestFirstBelowTheCursor() {
    for id in 1...5 { addText(Int64(id)) }
    DB.writeSessionSketch([1], textStoreId: 4, db: db)
    #expect(DB.unsketchedTextStoreIds(beforeId: .max, limit: 2, db: db) == [5, 3])
    #expect(DB.unsketchedTextStoreIds(beforeId: 3, limit: 10, db: db) == [2, 1])
    #expect(DB.unsketchedTextStoreIds(beforeId: 1, limit: 10, db: db).isEmpty)
  }

  @Test func storedSessionsRoundTripAndReplace() throws {
    let record = SessionDayRecord(dayStartMs: 86_400_000, windowStartMs: 75_600_000, windowEndMs: 183_600_000, params: "v1|balanced",
                                  fingerprint: SessionDayFingerprint(snapshotCount: 9, maxSnapshotId: 42, textCount: 8, sketchedCount: 8),
                                  computedAtMs: 200_000_000)
    let sessions = [
      ActivitySession(id: 10, startMs: 90_000_000, endMs: 91_000_000, snapshotCount: 5,
                      apps: [.init(bundleId: "com.apple.dt.Xcode", name: "Xcode", ms: 600_000), .init(bundleId: nil, name: nil, ms: 5)],
                      keywords: ["TimelineBarView", "日本語", "quote\"d"]),
      ActivitySession(id: 20, startMs: 92_000_000, endMs: 92_500_000, snapshotCount: 4, apps: [], keywords: []),
    ]
    try DB.replaceActivitySessions(sessions, record: record, db: db)
    #expect(DB.sessionDayRecord(dayStartMs: record.dayStartMs, db: db) == record)
    #expect(DB.activitySessions(dayStartMs: record.dayStartMs, db: db) == sessions)

    try DB.replaceActivitySessions([sessions[1]], record: record, db: db)
    #expect(DB.activitySessions(dayStartMs: record.dayStartMs, db: db) == [sessions[1]])
    #expect(DB.sessionDayRecord(dayStartMs: 0, db: db) == nil)
  }

  @Test func deletingACaptureInvalidatesOnlyDaysWhoseWindowHoldsIt() throws {
    func record(_ day: Int64) -> SessionDayRecord {
      SessionDayRecord(dayStartMs: day, windowStartMs: day - 10, windowEndMs: day + 110, params: "v1|balanced",
                       fingerprint: SessionDayFingerprint(snapshotCount: 0, maxSnapshotId: 0, textCount: 0, sketchedCount: 0),
                       computedAtMs: 0)
    }
    try DB.replaceActivitySessions([], record: record(100), db: db)
    try DB.replaceActivitySessions([], record: record(200), db: db)
    try DB.replaceActivitySessions([], record: record(300), db: db)
    exec(DB.sessionDayInvalidationSQL(windowContaining: "205"))   // inside day 200, and day 100's trailing context
    #expect(count("SELECT COUNT(*) FROM ts_session_day;") == 1)
    #expect(DB.sessionDayRecord(dayStartMs: 300, db: db) != nil)
  }

  @Test func sketchesOfDeletedTextsAreRemoved() {
    addText(1); addText(2)
    DB.writeSessionSketch([1], textStoreId: 1, db: db)
    DB.writeSessionSketch([2], textStoreId: 2, db: db)
    exec("DELETE FROM ts_text_store WHERE id = 1;")
    exec(DB.orphanedSessionSketchDeletionSQL)
    #expect(count("SELECT COUNT(*) FROM ts_session_sketch;") == 1)
    #expect(count("SELECT text_store_id FROM ts_session_sketch;") == 2)
  }

  @Test func clearingAllDaysEmptiesBothTables() throws {
    let record = SessionDayRecord(dayStartMs: 1, windowStartMs: 0, windowEndMs: 2, params: "v1|strict",
                                  fingerprint: SessionDayFingerprint(snapshotCount: 0, maxSnapshotId: 0, textCount: 0, sketchedCount: 0),
                                  computedAtMs: 0)
    try DB.replaceActivitySessions([ActivitySession(id: 1, startMs: 1, endMs: 1, snapshotCount: 1, apps: [], keywords: [])], record: record, db: db)
    exec(DB.allSessionDaysDeletionSQL)
    #expect(count("SELECT COUNT(*) FROM ts_session_day;") == 0)
    #expect(count("SELECT COUNT(*) FROM ts_activity_session;") == 0)
  }
}
