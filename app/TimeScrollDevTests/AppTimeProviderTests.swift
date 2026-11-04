import Foundation
import Testing
@testable import TimeScroll

/// App time end to end against a throwaway database file.
@Suite(.serialized)
final class AppTimeProviderTests {
  private let database: SummaryTestDatabase
  private let hour: Int64 = 3_600_000
  private var day: Int64 { 24 * hour }
  private let start = SummaryTestTime.ms(2026, 1, 15)
  private var nowMs = SummaryTestTime.ms(2026, 3, 1)
  private var zone = "UTC"
  private lazy var provider = AppTimeProvider(database: database,
                                              calendar: { [unowned self] in SummaryTestTime.calendar(self.zone) },
                                              now: { [unowned self] in self.nowMs },
                                              pauseBetweenBuilds: 0)

  init() throws {
    database = try SummaryTestDatabase()
  }

  /// One capture every 5 s for `minutes`, starting at `from`.
  private func addWork(from: Int64, minutes: Int64, app: String = "com.app") {
    database.addCaptures(stride(from: from, to: from + minutes * 60_000, by: 5_000).map { ($0, app) })
  }

  private var builtDays: Int { database.count("SELECT COUNT(*) FROM ts_app_time_day;") }

  @Test func emptyDatabaseReportsZeroAndRemembersEmptyDays() throws {
    let report = try #require(provider.report(fromMs: start, toMs: start + day))
    #expect(report.totalDwellMs == 0)
    #expect(report.topApps.isEmpty)
    #expect(builtDays == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_app_time;") == 0)
  }

  @Test func buildingADayMatchesReadingItsCaptures() throws {
    addWork(from: start + 9 * hour, minutes: 60, app: "com.a")
    addWork(from: start + 11 * hour, minutes: 30, app: "com.b")
    let exact = try #require(provider.report(fromMs: start + 8 * hour, toMs: start + 12 * hour))
    #expect(exact.range.precision == .exact)
    #expect(builtDays == 0)

    let whole = try #require(provider.report(fromMs: start, toMs: start + day))
    #expect(whole.range.precision == .quarterHour)
    #expect(builtDays == 1)
    #expect(whole.totalDwellMs == exact.totalDwellMs)
    #expect(whole.topApps == exact.topApps)
    #expect(whole.topApps.map(\.app) == ["com.a", "com.b"])
    #expect(whole.topApps[0].name == "com.a")
  }

  @Test func readsAcrossPrecisionsAgree() throws {
    for offset in 0..<30 { addWork(from: start + Int64(offset) * day + 10 * hour, minutes: 10, app: "com.app\(offset % 3)") }
    let quarter = try #require(provider.report(fromMs: start, toMs: start + 14 * day))
    let dayPrecision = try #require(provider.report(fromMs: start, toMs: start + 30 * day))
    #expect(quarter.range.precision == .quarterHour)
    #expect(dayPrecision.range.precision == .day)
    #expect(dayPrecision.snapshotCount == 30 * 120)
    #expect(quarter.snapshotCount == 14 * 120)
    #expect(dayPrecision.distinctApps == 3)
  }

  @Test func partialDayEdgesUseQuarterHours() throws {
    addWork(from: start + 10 * hour, minutes: 30)
    addWork(from: start + day + 10 * hour, minutes: 30)
    addWork(from: start + 2 * day + 10 * hour, minutes: 30)
    // From inside the first day's work to inside the third's, on quarter hours.
    let report = try #require(provider.report(fromMs: start + 10 * hour + 15 * 60_000, toMs: start + 2 * day + 10 * hour + 15 * 60_000))
    // The last half of the first day's work, all of the second's, and the first half of the third's.
    #expect(report.snapshotCount == 180 + 360 + 180)
  }

  @Test func audioDoesNotCount() throws {
    database.addCapture(at: start + hour, app: "com.a")
    database.addCapture(at: start + hour + 1_000, app: "com.a", kind: "audio")
    let report = try #require(provider.report(fromMs: start, toMs: start + 2 * hour))
    #expect(report.snapshotCount == 1)
    #expect(report.totalDwellMs == 5_000)
  }

  @Test func capturesWithoutAnAppAreUnknown() throws {
    database.addCapture(at: start + hour, app: nil)
    let report = try #require(provider.report(fromMs: start, toMs: start + 2 * hour))
    #expect(report.topApps.map(\.app) == [AppTimeRow.unknownApp])
    #expect(report.distinctApps == 0)
    #expect(report.topApps[0].name == nil)
  }

  @Test func oneAppAndSeriesFilterTheirRows() throws {
    addWork(from: start + 9 * hour, minutes: 30, app: "com.a")
    addWork(from: start + 10 * hour, minutes: 30, app: "com.b")
    #expect(provider.appTime(fromMs: start, toMs: start + day, app: "com.b") == Int64(1_800_000))
    #expect(provider.appTime(fromMs: start, toMs: start + day, app: "com.none") == Int64(0))

    let hours = try #require(provider.series(fromMs: start, toMs: start + day, granularity: .hour, app: "com.a"))
    #expect(hours.map(\.startMs) == [start + 9 * hour])
    let minutes = try #require(provider.series(fromMs: start + 9 * hour, toMs: start + 9 * hour + 120_000, granularity: .minute))
    #expect(minutes.map(\.startMs) == [start + 9 * hour, start + 9 * hour + 60_000])
    let coarsened = try #require(provider.series(fromMs: start, toMs: start + 20 * day, granularity: .minute))
    #expect(coarsened.map(\.startMs) == [start])
  }

  @Test func todayIsReadFromCapturesAndNotStored() throws {
    nowMs = start + 12 * hour
    addWork(from: start + 9 * hour, minutes: 10)
    let first = try #require(provider.report(fromMs: start, toMs: start + day))
    #expect(first.snapshotCount == 120)
    #expect(builtDays == 0)
    addWork(from: start + 11 * hour, minutes: 10)
    #expect(provider.report(fromMs: start, toMs: start + day)?.snapshotCount == 240)
  }

  @Test func midnightDwellStaysWithTheDayItStarted() throws {
    database.addCapture(at: start + day - 1_000, app: "com.a")
    database.addCapture(at: start + day + 59_000, app: "com.b")
    #expect(provider.report(fromMs: start, toMs: start + day)?.totalDwellMs == 60_000)
    #expect(provider.report(fromMs: start + day, toMs: start + 2 * day)?.totalDwellMs == 5_000)
  }

  @Test func deletingACaptureRebuildsItsDayAndKeepsOthers() throws {
    addWork(from: start + 9 * hour, minutes: 10)
    addWork(from: start + day + 9 * hour, minutes: 10)
    _ = provider.report(fromMs: start, toMs: start + 2 * day)
    #expect(builtDays == 2)

    database.exec("DELETE FROM ts_snapshot WHERE started_at_ms = \(start + 9 * hour);")
    database.exec(DB.summaryInvalidationSQL(captureAt: "\(start + 9 * hour)"))
    #expect(builtDays == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_app_time WHERE bucket_ms < \(start + day);") == 0)
    #expect(database.count("SELECT COUNT(*) FROM ts_app_time WHERE bucket_ms >= \(start + day);") > 0)
    #expect(provider.report(fromMs: start, toMs: start + day)?.snapshotCount == 119)
  }

  @Test func deletingJustAfterMidnightAlsoRebuildsThePreviousDay() throws {
    database.addCapture(at: start + day - 1_000)
    database.addCapture(at: start + day + 10 * 60_000)
    _ = provider.report(fromMs: start, toMs: start + 2 * day)
    #expect(builtDays == 2)
    #expect(provider.report(fromMs: start, toMs: start + day)?.totalDwellMs == 60_000)

    database.exec("DELETE FROM ts_snapshot WHERE started_at_ms = \(start + day + 10 * 60_000);")
    database.exec(DB.summaryInvalidationSQL(captureAt: "\(start + day + 10 * 60_000)"))
    #expect(builtDays == 0)
    #expect(provider.report(fromMs: start, toMs: start + day)?.totalDwellMs == 5_000)
  }

  @Test func aCaptureQueuedWhileLockedShowsUpInABuiltDay() throws {
    addWork(from: start + 9 * hour, minutes: 10)
    #expect(provider.report(fromMs: start, toMs: start + day)?.snapshotCount == 120)
    database.addCapture(at: start + 20 * hour)
    database.exec(DB.summaryInvalidationSQL(captureAt: "\(start + 20 * hour)"))
    #expect(provider.report(fromMs: start, toMs: start + day)?.snapshotCount == 121)
  }

  @Test func retentionDropsEveryDayItTouches() throws {
    for offset in 0..<3 { addWork(from: start + Int64(offset) * day + 9 * hour, minutes: 10) }
    _ = provider.report(fromMs: start, toMs: start + 3 * day)
    #expect(builtDays == 3)

    let cutoff = start + day + 12 * hour
    database.exec("DELETE FROM ts_snapshot WHERE started_at_ms < \(cutoff);")
    database.exec(DB.summaryRetentionSQL(cutoffMs: cutoff))
    #expect(builtDays == 1)
    #expect(database.count("SELECT COUNT(*) FROM ts_app_time WHERE bucket_ms < \(start + 2 * day);") == 0)
    #expect(provider.report(fromMs: start, toMs: start + 3 * day)?.snapshotCount == 120)
  }

  @Test func aBuildThatRacesADeleteStoresNothing() throws {
    let oneDay = SessionDayPlanner.day(containing: start, calendar: SummaryTestTime.calendar())
    let rollup = AppTimeRollup.Day(quarterHours: [AppTimeRow(bucketMs: start, app: "a", dwellMs: 1, snapshotCount: 1)], day: [])
    let expected = DB.summaryInvalidationCount(db: database.db)
    database.exec(DB.summaryInvalidationSQL(captureAt: "\(start)"))
    #expect(try DB.replaceAppTimeDay(oneDay, rollup: rollup, computedAtMs: 0, expectedInvalidations: expected, db: database.db) == false)
    #expect(builtDays == 0)
    #expect(database.count("SELECT COUNT(*) FROM ts_app_time;") == 0)
  }

  @Test func anOldVersionIsRebuilt() throws {
    addWork(from: start + 9 * hour, minutes: 10)
    _ = provider.report(fromMs: start, toMs: start + day)
    database.exec("UPDATE ts_app_time_day SET version = 0; UPDATE ts_app_time SET dwell_ms = 1;")
    #expect(provider.report(fromMs: start, toMs: start + day)?.totalDwellMs == Int64(600_000))
    #expect(database.count("SELECT MIN(version) FROM ts_app_time_day;") == AppTimeRollup.version)
  }

  @Test func changingTimeZoneRebuildsWithoutDoubleCounting() throws {
    addWork(from: start + 9 * hour, minutes: 10)
    addWork(from: start + day + 9 * hour, minutes: 10)
    #expect(provider.report(fromMs: start, toMs: start + 2 * day)?.snapshotCount == 240)
    #expect(builtDays == 2)

    zone = "Asia/Tokyo"
    let tokyo = SessionDayPlanner.day(containing: start + 9 * hour, calendar: SummaryTestTime.calendar(zone))
    let report = try #require(provider.report(fromMs: tokyo.startMs, toMs: tokyo.startMs + 3 * day))
    #expect(report.snapshotCount == 240)
    #expect(database.count("SELECT COUNT(*) FROM ts_app_time_day WHERE day_start_ms % 86400000 != \(((tokyo.startMs % day) + day) % day);") == 0)
    #expect(database.count("SELECT COALESCE(SUM(snapshot_count), 0) FROM ts_app_time WHERE span = 1;") == 240)
  }

  @Test func coverageReportsEachDay() throws {
    nowMs = start + 3 * day + hour
    addWork(from: start + day + 9 * hour, minutes: 10)
    _ = provider.report(fromMs: start + 2 * day, toMs: start + 3 * day)
    let coverage = try #require(provider.coverage(fromMs: start, toMs: start + 4 * day))
    #expect(coverage.map(\.state) == [.noCaptures, .pending, .built, .inProgress])
    #expect(provider.coverage(fromMs: start, toMs: start)?.isEmpty == true)
  }

  @Test func backfillBuildsMissingDays() throws {
    addWork(from: start + 9 * hour, minutes: 10)
    let done = DispatchSemaphore(value: 0)
    provider.backfill(fromMs: start, toMs: start + 5 * day) { done.signal() }
    #expect(done.wait(timeout: .now() + 10) == .success)
    #expect(builtDays == 5)
  }

  @Test func lockedVaultReturnsNil() {
    database.isLocked = true
    #expect(provider.report(fromMs: start, toMs: start + day) == nil)
    #expect(provider.appTime(fromMs: start, toMs: start + day, app: "a") == nil)
    #expect(provider.series(fromMs: start, toMs: start + day, granularity: .hour) == nil)
    #expect(provider.coverage(fromMs: start, toMs: start + day) == nil)
  }

  @Test func aDayFullOfAppsStaysBoundedAndExact() throws {
    let captures = (0..<500).map { (start + Int64($0) * 1_000, "com.app\($0)") }
    database.addCaptures(captures)
    let report = try #require(provider.report(fromMs: start, toMs: start + day))
    #expect(report.totalDwellMs == 499_000 + 5_000)
    #expect(report.snapshotCount == 500)
    #expect(report.topApps.count == 100)
    #expect(report.distinctAppsIsLowerBound)
    #expect(database.count("SELECT COUNT(*) FROM ts_app_time WHERE span = 1;") == 101)
  }
}
