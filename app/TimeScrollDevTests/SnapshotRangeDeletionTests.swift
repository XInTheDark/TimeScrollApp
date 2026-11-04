import Foundation
import Testing
@testable import TimeScroll

final class SnapshotRangeDeletionTests {
  private let database: SnapshotRangeTestDatabase
  private let day: Int64 = 86_400_000

  init() throws {
    database = try SnapshotRangeTestDatabase()
  }

  private func filter(_ from: Int64, _ to: Int64, apps: [String] = [], kinds: [CaptureKind] = [], sources: [AudioSourceKind] = []) -> SnapshotRangeFilter {
    SnapshotRangeFilter(fromMs: from, toMs: to, appBundleIds: apps, captureKinds: kinds, audioSourceKinds: sources)
  }

  private func snapshotCount() -> Int { database.count("SELECT COUNT(*) FROM ts_snapshot;") }

  @Test func rangeIsHalfOpen() throws {
    for time: Int64 in [99, 100, 150, 199, 200] { database.addSnapshot(at: time) }
    let result = try database.deleteAll(matching: filter(100, 200))
    #expect(result.removed == 3)
    #expect(database.count("SELECT COUNT(*) FROM ts_snapshot WHERE started_at_ms IN (99, 200);") == 2)
    #expect(snapshotCount() == 2)
  }

  @Test func emptyRangeRemovesNothing() throws {
    database.addSnapshot(at: 10)
    let result = try database.deleteAll(matching: filter(100, 200))
    #expect(result.removed == 0)
    #expect(result.files.isEmpty)
    #expect(snapshotCount() == 1)
  }

  @Test func everythingStoredWithASnapshotGoes() throws {
    let kept = database.addSnapshot(at: 500)
    database.addSnapshot(at: 100)
    database.addSnapshot(at: 200)
    _ = try database.deleteAll(matching: filter(0, 300))
    for table in ["ts_embedding", "ts_ocr_boxes", "ts_ocr_layout"] {
      #expect(database.count("SELECT COUNT(*) FROM \(table);") == 1)
      #expect(database.count("SELECT COUNT(*) FROM \(table) WHERE snapshot_id = \(kept);") == 1)
    }
    #expect(database.count("SELECT COUNT(*) FROM ts_text_index;") == 1)
  }

  @Test func onlyMatchingRowsGoWhenFiltered() throws {
    database.addSnapshot(at: 100, app: "com.slack")
    database.addSnapshot(at: 101, app: "com.xcode")
    let result = try database.deleteAll(matching: filter(0, 1_000, apps: ["com.slack"]))
    #expect(result.removed == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_snapshot WHERE app_bundle_id = 'com.xcode';") == 1)
  }

  @Test func mediaFiltersMatchTheTimelineQuery() throws {
    database.addSnapshot(at: 100)
    database.addSnapshot(at: 101, kind: "audio", source: "microphone")
    database.addSnapshot(at: 102, kind: "audio", source: "system")
    #expect(try database.deleteAll(matching: filter(0, 1_000, kinds: [.audio], sources: [.system])).removed == 1)
    #expect(try database.deleteAll(matching: filter(0, 1_000, kinds: [.audio])).removed == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_snapshot WHERE capture_kind = 'screen';") == 1)
  }

  @Test func quotesInAppIdsCannotChangeTheStatement() throws {
    database.addSnapshot(at: 100, app: "com.a")
    let result = try database.deleteAll(matching: filter(0, 1_000, apps: ["x' OR '1'='1"]))
    #expect(result.removed == 0)
    #expect(snapshotCount() == 1)
  }

  @Test func countsSplitByKindAndHonorFilters() {
    database.addSnapshot(at: 100, app: "com.a")
    database.addSnapshot(at: 101, app: "com.b")
    database.addSnapshot(at: 102, app: "com.a", kind: "audio", source: "microphone")
    database.addSnapshot(at: 5_000)
    #expect(DB.countSnapshots(matching: filter(0, 1_000), db: database.db) == .init(screen: 2, audio: 1))
    #expect(DB.countSnapshots(matching: filter(0, 1_000, apps: ["com.a"]), db: database.db) == .init(screen: 1, audio: 1))
    #expect(DB.countSnapshots(matching: filter(0, 1_000, kinds: [.audio]), db: database.db) == .init(screen: 0, audio: 1))
    #expect(DB.countSnapshots(matching: filter(2_000, 3_000), db: database.db) == .init(screen: 0, audio: 0))
  }

  @Test func allRowsGoAcrossBatches() throws {
    for time in Int64(0)..<23 { database.addSnapshot(at: time) }
    let first = try DB.deleteSnapshotBatch(matching: filter(0, 100), limit: 10, nowMs: 1_000_000, db: database.db)
    #expect(first.removed == 10)
    #expect(snapshotCount() == 13)
    #expect(try database.deleteAll(matching: filter(0, 100), limit: 10).removed == 13)
  }

  // MARK: - Shared data

  @Test func textUsedByAnotherSnapshotStays() throws {
    database.addSnapshot(at: 100, textStoreId: 1)
    database.addSnapshot(at: 500, textStoreId: 1)
    database.addSnapshot(at: 110, textStoreId: 2)
    _ = try database.deleteAll(matching: filter(0, 300))
    #expect(database.count("SELECT COUNT(*) FROM ts_text_store WHERE id = 1;") == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_session_sketch WHERE text_store_id = 1;") == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_text_store WHERE id = 2;") == 0)
    #expect(database.count("SELECT COUNT(*) FROM ts_session_sketch WHERE text_store_id = 2;") == 0)
  }

  @Test func sharedSegmentStaysWhileAnyRowUsesIt() throws {
    let segment = "/media/seg-2026-10-30-21-00-00-d1.mov"
    database.addSnapshot(at: 100, path: segment)
    database.addSnapshot(at: 500, path: segment)
    #expect(try database.deleteAll(matching: filter(0, 300)).files.isEmpty)
    #expect(try database.deleteAll(matching: filter(0, 1_000)).files == [segment])
  }

  @Test func aSegmentCaptureMayStillWriteToIsLeftAlone() throws {
    let nowMs: Int64 = 10_000_000
    database.addSnapshot(at: nowMs - 30_000, path: "/media/seg-2026-10-30-21-00-00-d1.mov")
    #expect(try database.deleteAll(matching: filter(0, nowMs), nowMs: nowMs).files.isEmpty)
    #expect(snapshotCount() == 0)
  }

  @Test func segmentSharedAcrossABatchBoundaryGoesOnce() throws {
    let segment = "/media/2026/shared.heic"
    for time in Int64(0)..<6 { database.addSnapshot(at: time, path: segment) }
    let result = try database.deleteAll(matching: filter(0, 100), limit: 4)
    #expect(result.files == [segment])
  }

  @Test func aSegmentsLiveAndSealedFilesCountAsTheSameMedia() throws {
    database.addSnapshot(at: 100, path: "/media/seg-2026-10-30-21-00-00-d1.tse")
    database.addSnapshot(at: 500, path: "/media/seg-2026-10-30-21-00-00-d1.mov")
    #expect(try database.deleteAll(matching: filter(0, 300)).files.isEmpty)
  }

  @Test func mediaInUseLooksNearEachSparseTime() {
    let hour: Int64 = 3_600_000
    database.addSnapshot(at: 0, path: "/m/near-first")
    database.addSnapshot(at: 10 * hour, path: "/m/between")
    database.addSnapshot(at: 20 * hour + 60_000, path: "/m/near-second")
    #expect(DB.mediaInUse(aroundTimes: [0, 20 * hour], db: database.db) == ["/m/near-first", "/m/near-second"])
    #expect(DB.mediaInUse(aroundTimes: [], db: database.db) == [])
  }

  @Test func thumbnailsGoWithTheirRows() throws {
    database.addSnapshot(at: 100, path: "/m/a.heic", thumbPath: "/t/a.jpg")
    let result = try database.deleteAll(matching: filter(0, 1_000))
    #expect(Set(result.files) == ["/m/a.heic", "/t/a.jpg"])
  }

  @Test func filteredDeleteKeepsFilesOfRowsLeftBehind() throws {
    database.addSnapshot(at: 100, path: "/m/shared.heic", app: "com.a")
    database.addSnapshot(at: 101, path: "/m/shared.heic", app: "com.b")
    let result = try database.deleteAll(matching: filter(0, 1_000, apps: ["com.a"]))
    #expect(result.removed == 1)
    #expect(result.files.isEmpty)
  }

  // MARK: - Derived data

  @Test func overlappingSummariesAndDaysAreInvalidated() throws {
    database.addSnapshot(at: 3 * day + 100)
    database.exec("""
    INSERT INTO ts_range_summary(start_ms, end_ms, model, prompt_version, text, created_at_ms) VALUES
      (\(3 * day), \(4 * day), 'm', 1, 'the day', 1),
      (\(0), \(7 * day), 'm', 1, 'the week', 1),
      (\(5 * day), \(6 * day), 'm', 1, 'another day', 1);
    INSERT INTO ts_session_day VALUES (\(3 * day), \(3 * day - 1_000), \(4 * day + 1_000)), (\(5 * day), \(5 * day), \(6 * day));
    """)
    let before = DB.summaryInvalidationCount(db: database.db)
    _ = try database.deleteAll(matching: filter(3 * day, 4 * day))
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary;") == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_range_summary WHERE text = 'another day';") == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_session_day;") == 1)
    #expect(DB.summaryInvalidationCount(db: database.db) > before)
  }

  @Test func deletingNothingDoesNotInvalidate() throws {
    let before = DB.summaryInvalidationCount(db: database.db)
    _ = try database.deleteAll(matching: filter(0, 1_000))
    #expect(DB.summaryInvalidationCount(db: database.db) == before)
  }

  // MARK: - Filter from the timeline's query

  private func query(text: String = "", apps: [String]? = nil, start: Int64? = nil, end: Int64? = nil) -> TimelineQuery {
    TimelineQuery(text: text, useAI: false, fuzziness: .off, intelligentAccuracy: false, appBundleIds: apps,
                  captureKinds: nil, audioSourceKinds: nil, startMs: start, endMs: end)
  }

  @Test func filterComesFromWhatTheTimelineShows() {
    let range = TimelineRange(fromMs: 100, toMs: 200)!
    let plain = SnapshotRangeFilter(range: range, query: query())
    #expect(plain == filter(100, 200))
    #expect(plain?.isFiltered == false)
    #expect(SnapshotRangeFilter(range: range, query: query(apps: ["com.a"]))?.isFiltered == true)
  }

  @Test func textSearchCannotBeDeletedAsARange() {
    #expect(SnapshotRangeFilter(range: TimelineRange(fromMs: 100, toMs: 200)!, query: query(text: "invoice")) == nil)
  }

  @Test func filterStaysInsideTheQuerysDates() {
    let clipped = SnapshotRangeFilter(range: TimelineRange(fromMs: 100, toMs: 200)!, query: query(start: 120, end: 150))
    #expect(clipped?.fromMs == 120)
    // The query's end is inclusive; the filter's isn't.
    #expect(clipped?.toMs == 151)
  }
}
