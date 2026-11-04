import Foundation
import Testing
@testable import TimeScroll

struct AppTimeRollupTests {
  private func capture(_ time: Int64, _ app: String = "a") -> AppTimeCapture { AppTimeCapture(timeMs: time, app: app) }
  private let quarter = AppTimeRollup.quarterHourMs

  @Test func dwellFollowsTheSessionRule() {
    #expect(CaptureDwell.ms(gapToNextMs: 10_000) == 10_000)
    #expect(CaptureDwell.ms(gapToNextMs: 60_000) == 60_000)
    #expect(CaptureDwell.ms(gapToNextMs: 5 * 60_000) == 60_000)
    #expect(CaptureDwell.ms(gapToNextMs: 15 * 60_000) == 60_000)
    #expect(CaptureDwell.ms(gapToNextMs: 15 * 60_000 + 1) == 5_000)
    #expect(CaptureDwell.ms(gapToNextMs: 0) == 5_000)
    #expect(CaptureDwell.ms(gapToNextMs: -5) == 5_000)
    #expect(CaptureDwell.ms(gapToNextMs: 1) == 1)
  }

  @Test func noCapturesMakeNoRows() {
    #expect(AppTimeRollup.rows(captures: [], nextCaptureMs: nil, bucketMs: quarter).isEmpty)
    #expect(AppTimeRollup.day(captures: [], nextCaptureMs: 5, dayStartMs: 0) == AppTimeRollup.Day(quarterHours: [], day: []))
  }

  @Test func oneCaptureCountsTheIsolatedTime() {
    let rows = AppTimeRollup.rows(captures: [capture(1_000)], nextCaptureMs: nil, bucketMs: quarter)
    #expect(rows == [AppTimeRow(bucketMs: 0, app: "a", dwellMs: 5_000, snapshotCount: 1)])
  }

  @Test func lastCaptureMeasuresAgainstTheNextOutsideTheRange() {
    let rows = AppTimeRollup.rows(captures: [capture(0)], nextCaptureMs: 30_000, bucketMs: quarter)
    #expect(rows[0].dwellMs == 30_000)
  }

  @Test func dwellStaysInTheBucketWhereTheCaptureStarts() {
    let captures = [capture(quarter - 1_000, "a"), capture(quarter + 59_000, "b")]
    let rows = AppTimeRollup.rows(captures: captures, nextCaptureMs: nil, bucketMs: quarter)
    #expect(rows == [AppTimeRow(bucketMs: 0, app: "a", dwellMs: 60_000, snapshotCount: 1),
                     AppTimeRow(bucketMs: quarter, app: "b", dwellMs: 5_000, snapshotCount: 1)])
  }

  @Test func interleavedDisplaysNeverExceedRealTime() {
    // Two displays' captures, 1 s apart, with different apps in front.
    let captures = (0..<600).map { capture(Int64($0) * 1_000, $0 % 2 == 0 ? "a" : "b") }
    let rows = AppTimeRollup.rows(captures: captures, nextCaptureMs: 600_000, bucketMs: quarter)
    #expect(rows.reduce(0) { $0 + $1.dwellMs } == 600_000)
  }

  @Test func appsBeyondTheLimitFoldIntoOtherAndKeepTheTotal() {
    var captures: [AppTimeCapture] = []
    for app in 0..<150 { captures.append(capture(Int64(app) * 1_000, "app\(app)")) }
    let rows = AppTimeRollup.rows(captures: captures, nextCaptureMs: 150_000, bucketMs: quarter)
    #expect(rows.count == 101)
    #expect(rows.last?.app == AppTimeRow.otherApp)
    #expect(rows.last?.dwellMs == 50_000)
    #expect(rows.last?.snapshotCount == 50)
    #expect(rows.reduce(0) { $0 + $1.dwellMs } == 150_000)
  }

  @Test func exactlyTheLimitHasNoOther() {
    let captures = (0..<100).map { capture(Int64($0) * 1_000, "app\($0)") }
    let rows = AppTimeRollup.rows(captures: captures, nextCaptureMs: 100_000, bucketMs: quarter)
    #expect(rows.count == 100)
    #expect(!rows.contains { $0.app == AppTimeRow.otherApp })
  }

  @Test func dayRowsAndQuarterHoursAgree() {
    let captures = stride(from: Int64(0), to: 7_200_000, by: 5_000).map { capture($0, $0 < 3_600_000 ? "a" : "b") }
    let day = AppTimeRollup.day(captures: captures, nextCaptureMs: nil, dayStartMs: 0)
    #expect(day.quarterHours.count == 8)
    #expect(day.day.count == 2)
    #expect(day.quarterHours.reduce(0) { $0 + $1.dwellMs } == day.day.reduce(0) { $0 + $1.dwellMs })
    #expect(day.day.allSatisfy { $0.bucketMs == 0 })
  }

  @Test func floorAndCeilHandleEdges() {
    #expect(AppTimeRollup.floor(0, to: quarter) == 0)
    #expect(AppTimeRollup.floor(quarter - 1, to: quarter) == 0)
    #expect(AppTimeRollup.floor(quarter, to: quarter) == quarter)
    #expect(AppTimeRollup.floor(-1, to: quarter) == -quarter)
    #expect(AppTimeRollup.ceil(1, to: quarter) == quarter)
    #expect(AppTimeRollup.ceil(quarter, to: quarter) == quarter)
    #expect(AppTimeRollup.ceil(0, to: quarter) == 0)
  }

  @Test func reportSplitsTopAppsFromOther() {
    let range = ResolvedSummaryRange(fromMs: 0, toMs: 100, precision: .exact)
    let rows = [AppTimeRow(bucketMs: 0, app: "a", dwellMs: 30, snapshotCount: 3),
                AppTimeRow(bucketMs: 10, app: "a", dwellMs: 30, snapshotCount: 3),
                AppTimeRow(bucketMs: 0, app: "b", dwellMs: 20, snapshotCount: 2),
                AppTimeRow(bucketMs: 0, app: "c", dwellMs: 10, snapshotCount: 1),
                AppTimeRow(bucketMs: 0, app: AppTimeRow.unknownApp, dwellMs: 1, snapshotCount: 1)]
    let report = AppTimeReport(range: range, rows: rows, topK: 2)
    #expect(report.topApps.map(\.app) == ["a", "b"])
    #expect(report.topApps[0].dwellMs == 60)
    #expect(report.otherDwellMs == 11)
    #expect(report.totalDwellMs == 91)
    #expect(report.snapshotCount == 10)
    #expect(report.distinctApps == 3)
    #expect(!report.distinctAppsIsLowerBound)
  }

  @Test func reportCountsFoldedAppsAsOtherAndFlagsTheBound() {
    let range = ResolvedSummaryRange(fromMs: 0, toMs: 100, precision: .exact)
    let rows = [AppTimeRow(bucketMs: 0, app: "a", dwellMs: 30, snapshotCount: 3),
                AppTimeRow(bucketMs: 0, app: AppTimeRow.otherApp, dwellMs: 7, snapshotCount: 2)]
    let report = AppTimeReport(range: range, rows: rows, topK: 100)
    #expect(report.topApps.map(\.app) == ["a"])
    #expect(report.otherDwellMs == 7)
    #expect(report.totalDwellMs == 37)
    #expect(report.distinctApps == 1)
    #expect(report.distinctAppsIsLowerBound)
  }

  @Test func emptyReportIsZero() {
    let report = AppTimeReport(range: ResolvedSummaryRange(fromMs: 0, toMs: 0, precision: .exact), rows: [], topK: 100)
    #expect(report.topApps.isEmpty)
    #expect(report.totalDwellMs == 0)
    #expect(report.distinctApps == 0)
  }

  @Test func seriesGroupsFromLocalMidnight() {
    // Kathmandu is UTC+5:45, so its hours aren't on the UTC hour.
    let calendar = SummaryTestTime.calendar("Asia/Kathmandu")
    let nine = SummaryTestTime.ms(2026, 1, 15, 9, 0, zone: "Asia/Kathmandu")
    let rows = [AppTimeRow(bucketMs: nine, app: "a", dwellMs: 10, snapshotCount: 1),
                AppTimeRow(bucketMs: nine + 45 * 60_000, app: "b", dwellMs: 20, snapshotCount: 2),
                AppTimeRow(bucketMs: nine + 60 * 60_000, app: "a", dwellMs: 40, snapshotCount: 4)]
    #expect(AppTimeSeries.points(rows: rows, granularity: .hour, calendar: calendar) == [
      AppTimeSeries.Point(startMs: nine, dwellMs: 30, snapshotCount: 3),
      AppTimeSeries.Point(startMs: nine + 3_600_000, dwellMs: 40, snapshotCount: 4),
    ])
    let days = AppTimeSeries.points(rows: rows, granularity: .day, calendar: calendar)
    #expect(days == [AppTimeSeries.Point(startMs: SummaryTestTime.ms(2026, 1, 15, zone: "Asia/Kathmandu"), dwellMs: 70, snapshotCount: 7)])
  }

  @Test func seriesGranularityIsLimitedByPrecision() {
    #expect(AppTimeSeries.effective(.minute, precision: .exact) == .minute)
    #expect(AppTimeSeries.effective(.minute, precision: .quarterHour) == .quarterHour)
    #expect(AppTimeSeries.effective(.hour, precision: .quarterHour) == .hour)
    #expect(AppTimeSeries.effective(.minute, precision: .day) == .day)
  }
}
