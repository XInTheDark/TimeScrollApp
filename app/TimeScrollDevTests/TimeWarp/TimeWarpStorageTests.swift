import Foundation
import Testing
@testable import TimeScroll

final class TimeWarpStorageTests {
  private let database: TimeWarpTestDatabase

  init() throws {
    database = try TimeWarpTestDatabase()
  }

  private func ranges(_ value: String) -> [ClosedRange<Int64>] {
    database.spans().filter { $0.value == value }.map { $0.startMs...$0.endMs }.sorted { $0.lowerBound < $1.lowerBound }
  }

  // MARK: Writes

  @Test func stringsAreStoredOnce() {
    for index in 0..<5 { database.add("https://a/", title: "A", start: Int64(index), end: Int64(index)) }
    #expect(database.count("SELECT COUNT(*) FROM ts_tw_value;") == 3)
    #expect(database.count("SELECT COUNT(*) FROM ts_tw_span;") == 5)
  }

  @Test func sameTextInDifferentRolesStaysSeparate() {
    database.add("/x", kind: .document, start: 0, end: 1)
    database.add("/x", kind: .warpPoint, source: .event, start: 0, end: 0)
    #expect(database.count("SELECT COUNT(*) FROM ts_tw_value WHERE value = '/x';") == 2)
  }

  @Test func closeNeverEndsBeforeTheStart() {
    let id = database.add("https://a/", start: 500, end: 500, isOpen: true)
    _ = DB.timeWarpUpdate(ids: [id], sql: DB.timeWarpCloseSQL, endMs: 100, db: database.db)
    #expect(ranges("https://a/") == [500...500])
    #expect(!database.isOpen(id))
  }

  // MARK: Range queries

  @Test func rangeQueryFindsOverlapsOnly() {
    database.add("https://before/", start: 0, end: 99)
    database.add("https://crossing/", start: 50, end: 150)
    database.add("https://inside/", start: 120, end: 130)
    database.add("https://after/", start: 200, end: 300)
    database.add("note", kind: .warpPoint, source: .event, start: 100, end: 100)
    let values = Set(database.spans(100, 200).map(\.value))
    #expect(values == ["https://crossing/", "https://inside/", "note"])
  }

  @Test func aSpanInProgressRunsUntilNow() {
    // Stored ending where it started, and begun before the range.
    database.add("https://live/", start: 100, end: 100, isOpen: true)
    let found = DB.timeWarpSpans(fromMs: 300, toMs: 1_000, db: database.db, nowMs: 800)
    #expect(found.map(\.endMs) == [800])
    let capped = DB.timeWarpSpans(fromMs: 0, toMs: .max / 4, db: database.db, nowMs: .max / 4)
    #expect(capped.map(\.endMs) == [100 + DB.timeWarpMaxSpanMs])
    #expect(DB.timeWarpSpans(fromMs: 300, toMs: 1_000, db: database.db, nowMs: 200).isEmpty)
  }

  @Test func rangeQueryReachesBackOneMaxSpan() {
    let max = DB.timeWarpMaxSpanMs
    database.add("https://long/", start: 0, end: max)
    #expect(database.spans(max - 1, max + 10).count == 1)
  }

  @Test func recordsComeBackWithTheirStrings() {
    database.add("https://a/", title: "Title", app: "com.google.Chrome", start: 1, end: 2)
    let record = database.spans().first
    #expect(record == TimeWarpSpanRecord(kind: .page, source: .front, value: "https://a/", title: "Title",
                                         appBundleId: "com.google.Chrome", startMs: 1, endMs: 2))
  }

  @Test func countsDistinctItemsIncludingAppsAndFilterByApp() {
    database.add("com.a", kind: .app, start: 0, end: 100)
    database.add("https://a/", app: "com.a", start: 0, end: 40)
    database.add("https://a/", app: "com.a", start: 60, end: 100)
    database.add("https://b/", app: "com.b", start: 0, end: 100)
    #expect(DB.countTimeWarpSpans(fromMs: 0, toMs: 100, db: database.db) == 3)
    #expect(DB.countTimeWarpSpans(fromMs: 0, toMs: 50, appBundleIds: ["com.b"], db: database.db) == 1)
    #expect(DB.countTimeWarpSpans(fromMs: 500, toMs: 600, db: database.db) == 0)
  }

  @Test func aRangeWithOnlyAppsCountsAndDeletes() throws {
    database.add("com.a", kind: .app, start: 0, end: 100)
    #expect(DB.countTimeWarpSpans(fromMs: 0, toMs: 100, db: database.db) == 1)
    try database.delete(0, 100)
    #expect(DB.countTimeWarpSpans(fromMs: 0, toMs: 100, db: database.db) == 0)
  }

  // MARK: Deletion

  @Test func deletingRemovesEveryTouchingSpanWhole() throws {
    database.add("https://crossing/", start: 0, end: 1_000)
    database.add("https://inside/", start: 200, end: 250)
    database.add("https://before/", start: 0, end: 100)
    database.add("https://after/", start: 500, end: 600)
    try database.delete(200, 300)
    #expect(Set(database.spans().map(\.value)) == ["https://before/", "https://after/"])
    // Strings no record uses are gone too.
    #expect(database.count("SELECT COUNT(*) FROM ts_tw_value WHERE value IN ('https://crossing/', 'https://inside/');") == 0)
  }

  @Test func deletingIsHalfOpen() throws {
    database.add("at-start", kind: .warpPoint, source: .event, start: 200, end: 200)
    database.add("at-end", kind: .warpPoint, source: .event, start: 400, end: 400)
    database.add("https://ends-at-start/", start: 0, end: 200)
    try database.delete(200, 400)
    #expect(Set(database.spans().map(\.value)) == ["at-end", "https://ends-at-start/"])
  }

  @Test func deletingOnlyMatchingApps() throws {
    database.add("https://a/", app: "com.a", start: 0, end: 1_000)
    database.add("https://b/", app: "com.b", start: 0, end: 1_000)
    try database.delete(200, 300, apps: ["com.a"])
    #expect(Set(database.spans().map(\.value)) == ["https://b/"])
  }

  @Test func emptyOrInvertedRangeDeletesNothing() throws {
    database.add("https://a/", start: 0, end: 1_000)
    try database.delete(500, 500)
    try database.delete(600, 500)
    #expect(ranges("https://a/") == [0...1_000])
  }

  @Test func aSpanInProgressBeforeTheRangeIsDeleted() throws {
    // Still being recorded, so it runs through the deleted range.
    database.add("https://live/", start: 1_000, end: 1_000, isOpen: true)
    database.add("https://later/", start: 4_000, end: 4_000, isOpen: true)
    try database.delete(2_000, 3_000)
    #expect(Set(database.spans().map(\.value)) == ["https://later/"])
  }

  // MARK: Value cache

  @Test func clearingTheValueCacheForgetsStaleIds() {
    let cache = TimeWarpValueCache()
    #expect(cache.id(domain: .url, value: "https://a/", db: database.db) == nil)
    cache.store(99, domain: .url, value: "https://a/")
    #expect(cache.id(domain: .url, value: "https://a/", db: database.db) == 99)
    // A closed database's ids must not answer for a new connection at the same address.
    cache.removeAll()
    #expect(cache.id(domain: .url, value: "https://a/", db: database.db) == nil)
  }

  @Test func anotherConnectionStartsWithAnEmptyCache() throws {
    let other = try TimeWarpTestDatabase()
    let cache = TimeWarpValueCache()
    _ = cache.id(domain: .url, value: "https://a/", db: database.db)
    cache.store(99, domain: .url, value: "https://a/")
    #expect(cache.id(domain: .url, value: "https://a/", db: other.db) == nil)
  }

  // MARK: Retention

  @Test func retentionDropsWhatEndedBeforeTheCutoff() throws {
    database.add("https://old/", start: 0, end: 900)
    database.add("https://crossing/", start: 500, end: 2_000)
    database.add("https://live/", start: 100, end: 100, isOpen: true)
    database.add("old note", kind: .warpPoint, source: .event, start: 800, end: 800)
    database.add("new note", kind: .warpPoint, source: .event, start: 1_500, end: 1_500)
    try DB.purgeTimeWarpRecords(olderThan: 1_000, db: database.db)
    #expect(Set(database.spans().map(\.value)) == ["https://crossing/", "https://live/", "new note"])
    #expect(database.count("SELECT COUNT(*) FROM ts_tw_value WHERE value = 'https://old/';") == 0)
  }

  @Test func retentionOnEmptyTablesIsFine() throws {
    try DB.purgeTimeWarpRecords(olderThan: 1_000, db: database.db)
    #expect(database.spans().isEmpty)
  }

  // MARK: Frame end

  @Test func aFrameLastsUntilTheNextScreenFrame() {
    database.exec("""
    INSERT INTO ts_snapshot(started_at_ms, capture_kind) VALUES (1000, 'screen'), (2000, 'audio'), (5000, 'screen');
    """)
    #expect(DB.timeWarpFrameEndMs(startedAtMs: 1_000, db: database.db) == 5_000)
  }

  @Test func theLastFrameLastsAtMostTenMinutes() {
    database.exec("INSERT INTO ts_snapshot(started_at_ms) VALUES (1000), (99000000);")
    #expect(DB.timeWarpFrameEndMs(startedAtMs: 1_000, db: database.db) == 601_000)
    #expect(DB.timeWarpFrameEndMs(startedAtMs: 99_000_000, db: database.db) == 99_600_000)
  }

  // MARK: Range filter

  @Test func rangeDeletesIncludeTimeWarpUnlessOnlyAudio() {
    #expect(SnapshotRangeFilter(fromMs: 0, toMs: 1, appBundleIds: [], captureKinds: [], audioSourceKinds: []).includesTimeWarpRecords)
    #expect(SnapshotRangeFilter(fromMs: 0, toMs: 1, appBundleIds: [], captureKinds: [.screen], audioSourceKinds: []).includesTimeWarpRecords)
    #expect(!SnapshotRangeFilter(fromMs: 0, toMs: 1, appBundleIds: [], captureKinds: [.audio], audioSourceKinds: []).includesTimeWarpRecords)
    #expect(!SnapshotRangeFilter(fromMs: 0, toMs: 1, appBundleIds: [], captureKinds: [], audioSourceKinds: [.system]).includesTimeWarpRecords)
  }

  @Test func rangeCountTextMentionsTimeWarp() {
    #expect(TimelineRangeFormat.counts(DB.SnapshotRangeCount(screen: 2, audio: 0, timeWarp: 3)) == "2 snapshots and 3 Time Warp items")
    #expect(TimelineRangeFormat.counts(DB.SnapshotRangeCount(screen: 0, audio: 0, timeWarp: 1)) == "1 Time Warp item")
    #expect(TimelineRangeFormat.counts(DB.SnapshotRangeCount(screen: 0, audio: 0, timeWarp: 0)) == "0 snapshots")
    #expect(!DB.SnapshotRangeCount(screen: 0, audio: 0, timeWarp: 1).isEmpty)
  }
}
