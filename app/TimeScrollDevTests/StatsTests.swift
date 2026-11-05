import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// An in-memory database holding only the tables the stats queries read.
private final class StatsTestDatabase {
  let handle: OpaquePointer

  init() throws {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else { throw NSError(domain: "StatsTests", code: 1) }
    handle = db
    try exec("""
      CREATE TABLE ts_usage_session(id INTEGER PRIMARY KEY AUTOINCREMENT, start_s REAL NOT NULL, end_s REAL);
      CREATE TABLE ts_snapshot(id INTEGER PRIMARY KEY, started_at_ms INTEGER NOT NULL, path TEXT NOT NULL, bytes INTEGER);
      """)
  }

  deinit { sqlite3_close(handle) }

  func exec(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "StatsTests", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
  }

  func addSession(_ start: Double, _ end: Double?) throws {
    try exec("INSERT INTO ts_usage_session(start_s, end_s) VALUES(\(start), \(end.map { "\($0)" } ?? "NULL"));")
  }

  func addSnapshot(atSeconds seconds: Double, path: String = "a.png", bytes: Int? = 10) throws {
    try exec("INSERT INTO ts_snapshot(started_at_ms, path, bytes) VALUES(\(Int64(seconds * 1000)), '\(path)', \(bytes.map(String.init) ?? "NULL"));")
  }

  func sessionEnds() throws -> [Double?] {
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(handle, "SELECT end_s FROM ts_usage_session ORDER BY id;", -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "StatsTests", code: 3) }
    var ends: [Double?] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      ends.append(sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 0))
    }
    return ends
  }

  func usage(from: Double?, to: Double) throws -> Double {
    try DB.usageSeconds(from: from, to: to, db: handle)
  }
}

@Suite struct StatsWindowTests {
  @Test func everyLabelMatchesItsDuration() {
    let expected: [String: TimeInterval?] = [
      "All time": nil, "1h": 3600, "6h": 21600, "24h": 86400,
      "7d": 604_800, "30d": 2_592_000, "90d": 7_776_000, "1y": 31_536_000,
    ]
    #expect(StatsWindow.all.count == expected.count)
    for window in StatsWindow.all {
      #expect(expected[window.label] == .some(window.seconds))
    }
  }

  @Test func cutoffs() {
    let day = StatsWindow(label: "24h", seconds: 86400)
    #expect(day.cutoffSeconds(now: 100_000) == 13600)
    #expect(day.cutoffMs(now: 100_000) == Int64(13_600_000))
    let all = StatsWindow(label: "All time", seconds: nil)
    #expect(all.cutoffSeconds(now: 100_000) == nil)
    #expect(all.cutoffMs(now: 100_000) == nil)
    #expect(all.isAllTime && !day.isAllTime)
  }
}

@Suite struct StatsSummaryTests {
  @Test func averageExcludesTheDatabaseAndEmptyIsZero() {
    let summary = StatsSummary(snapshotCount: 4, snapshotBytes: 400, databaseBytes: 1000, usageSeconds: 0)
    #expect(summary.storageBytes == Int64(1400))
    #expect(summary.averageSnapshotBytes == Int64(100))
    #expect(StatsSummary().averageSnapshotBytes == Int64(0))
    #expect(StatsSummary().storageBytes == Int64(0))
  }

  @Test func formatting() {
    #expect(StatsSummary.byteString(0) == "0.00 B")
    #expect(StatsSummary.byteString(1023) == "1023.00 B")
    #expect(StatsSummary.byteString(1024) == "1.00 KB")
    #expect(StatsSummary.byteString(1024 * 1024) == "1.00 MB")
    #expect(StatsSummary.byteString(Int64(1) << 50) == "1024.00 TB")
    #expect(StatsSummary.durationString(-5) == "0s")
    #expect(StatsSummary.durationString(0) == "0s")
    #expect(StatsSummary.durationString(59) == "59s")
    #expect(StatsSummary.durationString(61) == "1m 1s")
    #expect(StatsSummary.durationString(3660) == "1h 1m")
    #expect(StatsSummary.durationString(86400 * 30) == "720h 0m")
  }
}

@Suite struct UsageSecondsTests {
  @Test func emptyTableIsZero() throws {
    let db = try StatsTestDatabase()
    #expect(try db.usage(from: nil, to: 100) == 0)
    #expect(try db.usage(from: 50, to: 100) == 0)
  }

  @Test func eachWindowClipsAndAllTimeSumsEverything() throws {
    let db = try StatsTestDatabase()
    try db.addSession(0, 100)
    try db.addSession(200, 300)
    #expect(try db.usage(from: nil, to: 1000) == 200)
    #expect(try db.usage(from: 50, to: 1000) == 150)
    #expect(try db.usage(from: 250, to: 1000) == 50)
    #expect(try db.usage(from: 301, to: 1000) == 0)
    #expect(try db.usage(from: 50, to: 250) == 100)
  }

  @Test func windowNeverExceedsItsOwnLength() throws {
    let db = try StatsTestDatabase()
    try db.addSession(0, 1_000_000)
    #expect(try db.usage(from: 999_000, to: 1_000_000) == 1000)
  }

  @Test func overlappingAndContainedSessionsCountOnce() throws {
    let db = try StatsTestDatabase()
    try db.addSession(0, 100)
    try db.addSession(50, 150)
    try db.addSession(60, 70)
    try db.addSession(150, 160)
    #expect(try db.usage(from: nil, to: 1000) == 160)
    #expect(try db.usage(from: 65, to: 1000) == 95)
  }

  @Test func openSessionRunsUntilNow() throws {
    let db = try StatsTestDatabase()
    try db.addSession(100, nil)
    #expect(try db.usage(from: nil, to: 160) == 60)
    #expect(try db.usage(from: 150, to: 160) == 10)
    #expect(try db.usage(from: nil, to: 50) == 0)
  }

  @Test func invertedAndFutureRowsAddNothing() throws {
    let db = try StatsTestDatabase()
    try db.addSession(100, 50)
    try db.addSession(500, 600)
    #expect(try db.usage(from: nil, to: 200) == 0)
    #expect(try db.usage(from: 300, to: 200) == 0)
  }
}

@Suite struct CloseOrphanedSessionsTests {
  @Test func endsAtTheOrphansLastSnapshot() throws {
    let db = try StatsTestDatabase()
    try db.addSession(100, nil)
    try db.addSnapshot(atSeconds: 110)
    try db.addSnapshot(atSeconds: 150)
    #expect(DB.closeOrphanedUsageSessions(startedBefore: 1000, db: db.handle))
    #expect(try db.sessionEnds() == [150])
  }

  /// The downtime between a crash and the next launch must not count as usage, even when the new
  /// run's first snapshot reaches the database before the orphan gets closed.
  @Test func ignoresSnapshotsFromTheCurrentRun() throws {
    let db = try StatsTestDatabase()
    try db.addSession(100, nil)
    try db.addSnapshot(atSeconds: 150)
    try db.addSnapshot(atSeconds: 1_000_000)
    #expect(DB.closeOrphanedUsageSessions(startedBefore: 999_999, db: db.handle))
    #expect(try db.sessionEnds() == [150])
  }

  @Test func withNoSnapshotsOfItsOwnItLastsNoTime() throws {
    let db = try StatsTestDatabase()
    try db.addSession(100, nil)
    try db.addSnapshot(atSeconds: 1_000_000)
    #expect(DB.closeOrphanedUsageSessions(startedBefore: 999_999, db: db.handle))
    #expect(try db.sessionEnds() == [100])
    #expect(try db.usage(from: nil, to: 2_000_000) == 0)
  }

  @Test func severalOrphansStopAtTheNextOnesStart() throws {
    let db = try StatsTestDatabase()
    try db.addSession(100, nil)
    try db.addSession(500, nil)
    try db.addSnapshot(atSeconds: 150)
    try db.addSnapshot(atSeconds: 550)
    #expect(DB.closeOrphanedUsageSessions(startedBefore: 1000, db: db.handle))
    #expect(try db.sessionEnds() == [150, 550])
  }

  @Test func leavesTheCurrentRunsSessionOpenAndClosedOnesUntouched() throws {
    let db = try StatsTestDatabase()
    try db.addSession(10, 20)
    try db.addSession(1000, nil)
    try db.addSnapshot(atSeconds: 1500)
    #expect(DB.closeOrphanedUsageSessions(startedBefore: 999, db: db.handle))
    #expect(try db.sessionEnds() == [20, nil])
  }
}

@Suite struct UsageSessionRepairTests {
  /// The real case: months of downtime ended by the next run's first snapshot.
  @Test func removesDowntimeFromAnOrphanWithNoRemainingSnapshots() throws {
    let db = try StatsTestDatabase()
    try db.addSession(100, 16_000_000)
    try db.addSession(16_000_000, 16_000_100)
    try db.addSnapshot(atSeconds: 16_000_000)
    try db.addSnapshot(atSeconds: 16_000_100)
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    #expect(try db.sessionEnds() == [100, 16_000_100])
  }

  @Test func removesSleepFromASessionEndedByTheWakeRestart() throws {
    let db = try StatsTestDatabase()
    try db.addSnapshot(atSeconds: 1000)
    try db.addSnapshot(atSeconds: 2000)
    try db.addSession(1000, 40000)
    try db.addSession(40000.5, 41000)
    try db.addSnapshot(atSeconds: 40001)
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    #expect(try db.sessionEnds() == [2000, 41000])
  }

  @Test func keepsSessionsWithoutTheFaultsTrace() throws {
    let db = try StatsTestDatabase()
    try db.addSnapshot(atSeconds: 1000)
    // Snapshots right up to the end, then restarted immediately.
    try db.addSession(1000, 1600)
    try db.addSnapshot(atSeconds: 1599)
    // A quiet stretch, but the next session starts much later: a real stop.
    try db.addSession(1700, 9000)
    try db.addSnapshot(atSeconds: 1701)
    // The last session has no successor to compare with.
    try db.addSession(20000, 90000)
    let before = try db.sessionEnds()
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    #expect(try db.sessionEnds() == before)
  }

  @Test func leavesSessionsOlderThanEverySnapshotAlone() throws {
    let db = try StatsTestDatabase()
    try db.addSession(0, 10000)
    try db.addSession(10001, 20000)
    try db.addSnapshot(atSeconds: 50000)
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    #expect(try db.sessionEnds() == [10000, 20000])
  }

  @Test func leavesOpenSessionsAndEmptyTablesAlone() throws {
    let db = try StatsTestDatabase()
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    let other = try StatsTestDatabase()
    try other.addSession(100, nil)
    try other.addSession(200, nil)
    try other.addSnapshot(atSeconds: 110)
    DB.repairUsageSessionsIfNeeded(db: other.handle)
    #expect(try other.sessionEnds() == [nil, nil])
  }

  /// A session recorded after the repair may legitimately look like the fault; it must survive.
  @Test func runsOnlyOnce() throws {
    let db = try StatsTestDatabase()
    try db.addSnapshot(atSeconds: 1000)
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    try db.addSession(1000, 40000)
    try db.addSession(40000.5, 41000)
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    #expect(try db.sessionEnds() == [40000, 41000])
  }

  /// If the repair can't complete, it changes nothing and tries again on the next open.
  @Test func failureRollsBackAndRetries() throws {
    let db = try StatsTestDatabase()
    try db.exec("ALTER TABLE ts_snapshot RENAME TO ts_snapshot_hidden;")
    try db.addSession(0, 50000)
    try db.addSession(50001, 50002)
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    #expect(try db.sessionEnds() == [50000, 50002])
    try db.exec("ALTER TABLE ts_snapshot_hidden RENAME TO ts_snapshot;")
    try db.addSnapshot(atSeconds: 100)
    DB.repairUsageSessionsIfNeeded(db: db.handle)
    #expect(try db.sessionEnds() == [100, 50002])
  }
}

@Suite struct SnapshotStorageScanTests {
  @Test func emptyTable() throws {
    let db = try StatsTestDatabase()
    let scan = try DB.snapshotStorageScan(sinceMs: nil, db: db.handle)
    #expect(scan.count == 0 && scan.recordedBytes == Int64(0) && scan.unsizedPaths.isEmpty)
  }

  @Test func countsEverySnapshotButEachVideoOnce() throws {
    let db = try StatsTestDatabase()
    try db.addSnapshot(atSeconds: 1, path: "seg.mov", bytes: 100)
    try db.addSnapshot(atSeconds: 2, path: "seg.mov", bytes: 100)
    try db.addSnapshot(atSeconds: 3, path: "b.png", bytes: 7)
    let scan = try DB.snapshotStorageScan(sinceMs: nil, db: db.handle)
    #expect(scan.count == 3)
    #expect(scan.recordedBytes == Int64(107))
  }

  @Test func windowIsInclusiveAndExcludesOlderSnapshots() throws {
    let db = try StatsTestDatabase()
    try db.addSnapshot(atSeconds: 1, path: "old.png", bytes: 1)
    try db.addSnapshot(atSeconds: 2, path: "edge.png", bytes: 2)
    try db.addSnapshot(atSeconds: 3, path: "new.png", bytes: 4)
    let scan = try DB.snapshotStorageScan(sinceMs: 2000, db: db.handle)
    #expect(scan.count == 2)
    #expect(scan.recordedBytes == Int64(6))
    #expect(try DB.snapshotStorageScan(sinceMs: 9000, db: db.handle).count == 0)
  }

  @Test func reportsOnlyPathsWithNoRecordedSize() throws {
    let db = try StatsTestDatabase()
    try db.addSnapshot(atSeconds: 1, path: "open.mov", bytes: nil)
    try db.addSnapshot(atSeconds: 2, path: "open.mov", bytes: 0)
    try db.addSnapshot(atSeconds: 3, path: "partly.mov", bytes: 0)
    try db.addSnapshot(atSeconds: 4, path: "partly.mov", bytes: 50)
    let scan = try DB.snapshotStorageScan(sinceMs: nil, db: db.handle)
    #expect(scan.count == 4)
    #expect(scan.recordedBytes == Int64(50))
    #expect(scan.unsizedPaths == ["open.mov"])
  }
}

private final class FakeUsageStore: UsageSessionStore, @unchecked Sendable {
  private let lock = NSLock()
  private var nextId: Int64 = 1
  private var _sessions: [(start: Double, end: Double?)] = []
  private var _closeAttempts = 0
  var isLocked = false

  var sessions: [(start: Double, end: Double?)] { lock.withLock { _sessions } }
  var closeAttempts: Int { lock.withLock { _closeAttempts } }

  func beginUsageSession(start: TimeInterval) throws -> Int64 {
    try lock.withLock {
      if isLocked { throw NSError(domain: "locked", code: 1) }
      _sessions.append((start, nil))
      defer { nextId += 1 }
      return nextId
    }
  }

  func endUsageSession(id: Int64, end: TimeInterval) throws {
    lock.withLock { _sessions[Int(id) - 1].end = end }
  }

  func closeOrphanedUsageSessions(startedBefore launchTime: TimeInterval) -> Bool {
    lock.withLock {
      _closeAttempts += 1
      return !isLocked
    }
  }
}

@Suite struct UsageTrackerTests {
  private func ends(_ store: FakeUsageStore) -> [[Double?]] {
    store.sessions.map { [$0.start, $0.end] }
  }

  @Test func sleepEndsTheSessionAndWakeStartsAnother() {
    let store = FakeUsageStore()
    let tracker = UsageTracker(store: store, launchTime: 0)
    tracker.captureStarted(at: 10)
    tracker.systemWillSleep(at: 20)
    tracker.systemDidWake(at: 1000)
    tracker.closeOrphanedSessions()
    #expect(ends(store) == [[10, 20], [1000, nil]])
  }

  @Test func wakeRestartLeavesOneOpenSession() {
    let store = FakeUsageStore()
    let tracker = UsageTracker(store: store, launchTime: 0)
    tracker.captureStarted(at: 10)
    tracker.systemWillSleep(at: 20)
    tracker.systemDidWake(at: 1000)
    tracker.captureStopped(at: 1001)
    tracker.captureStarted(at: 1002)
    tracker.closeOrphanedSessions()
    #expect(ends(store) == [[10, 20], [1000, 1001], [1002, nil]])
  }

  @Test func restartBeforeTheWakeNoticeDoesNotDuplicate() {
    let store = FakeUsageStore()
    let tracker = UsageTracker(store: store, launchTime: 0)
    tracker.captureStarted(at: 10)
    tracker.systemWillSleep(at: 20)
    tracker.captureStopped(at: 1000)
    tracker.captureStarted(at: 1001)
    tracker.systemDidWake(at: 1002)
    tracker.closeOrphanedSessions()
    #expect(ends(store) == [[10, 20], [1001, nil]])
  }

  @Test func sleepWhileNotCapturingRecordsNothing() {
    let store = FakeUsageStore()
    let tracker = UsageTracker(store: store, launchTime: 0)
    tracker.systemWillSleep(at: 20)
    tracker.systemDidWake(at: 1000)
    tracker.closeOrphanedSessions()
    #expect(store.sessions.isEmpty)
  }

  @Test func stoppedDuringSleepStaysStoppedAfterWake() {
    let store = FakeUsageStore()
    let tracker = UsageTracker(store: store, launchTime: 0)
    tracker.captureStarted(at: 10)
    tracker.systemWillSleep(at: 20)
    tracker.captureStopped(at: 21)
    tracker.systemDidWake(at: 1000)
    tracker.closeOrphanedSessions()
    #expect(ends(store) == [[10, 20]])
  }

  @Test func repeatedStartsKeepOneSession() {
    let store = FakeUsageStore()
    let tracker = UsageTracker(store: store, launchTime: 0)
    tracker.captureStarted(at: 10)
    tracker.captureStarted(at: 11)
    tracker.appWillTerminate(at: 12)
    #expect(ends(store) == [[10, 12]])
  }

  @Test func lockedVaultRetriesOrphansAndBackfillsStartOnUnlock() {
    let store = FakeUsageStore()
    store.isLocked = true
    let tracker = UsageTracker(store: store, launchTime: 0)
    tracker.captureStarted(at: 10)
    tracker.closeOrphanedSessions()
    #expect(store.sessions.isEmpty)
    #expect(store.closeAttempts == 2)

    store.isLocked = false
    tracker.onVaultUnlocked()
    tracker.closeOrphanedSessions()
    #expect(ends(store) == [[10, nil]])
    #expect(store.closeAttempts == 3)
  }
}
