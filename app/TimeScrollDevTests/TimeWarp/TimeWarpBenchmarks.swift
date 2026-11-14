import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// Time Warp storage and planning on 60 days of heavy synthetic use (about 190k spans). Opt-in with
/// `TEST_RUNNER_TIMESCROLL_BENCHMARKS=1`. Timings are reported, not gated. With
/// `TIMESCROLL_BENCHMARK_OUTPUT` set, results are also written there as JSON.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARKS"] == "1"))
@MainActor
final class TimeWarpBenchmarks {
  private static let days = 60
  private static let start = SummaryTestTime.ms(2025, 1, 1)
  private static let dayMs: Int64 = 86_400_000
  private static let activeMs: Int64 = 8 * 3_600_000
  private static let frontItemsPerDay = 1_500
  private static let appSpansPerDay = 600
  private static let openSpansPerDay = 1_000
  private let database: TimeWarpTestDatabase

  init() throws {
    database = try TimeWarpTestDatabase()
  }

  private func report(_ name: String, _ value: Double, _ unit: String) {
    print(String(format: "BENCH %@ %.3f %@", name, value, unit))
    guard let path = ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARK_OUTPUT"] else { return }
    let line = "{\"name\":\"timewarp_\(name)\",\"value\":\(value),\"unit\":\"\(unit)\"}\n"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
  }

  private func milliseconds(_ body: () -> Void) -> Double {
    let begin = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
  }

  private func median(_ runs: Int = 15, _ body: () -> Void) -> Double {
    var times: [Double] = []
    for _ in 0..<runs { times.append(milliseconds(body)) }
    return times.sorted()[runs / 2]
  }

  private func span(_ kind: TimeWarpItemKind, _ value: String, _ source: TimeWarpSource, title: String?, app: String,
                    _ start: Int64, _ end: Int64) {
    let item = TimeWarpItem(kind: kind, value: value, title: title)
    _ = DB.timeWarpInsert(TimeWarpSpanStart(item: item, source: source, appBundleId: app, startMs: start),
                          endMs: end, isOpen: false, db: database.db, cache: database.cache)
  }

  /// Days of 8 active hours: pages and documents in front, app switches, background tabs.
  private func seed() -> Int {
    var count = 0
    var random = SystemRandomNumberGenerator()
    database.exec("BEGIN;")
    for day in 0..<Self.days {
      let dayStart = Self.start + Int64(day) * Self.dayMs + 9 * 3_600_000
      let step = Self.activeMs / Int64(Self.frontItemsPerDay)
      for index in 0..<Self.frontItemsPerDay {
        let at = dayStart + Int64(index) * step
        let page = Int.random(in: 0..<5_000, using: &random)
        if index % 5 == 0 {
          span(.document, "/Users/me/Documents/Project \(page % 300)/notes \(page).md", .front, title: nil, app: "com.microsoft.VSCode", at, at + step)
        } else {
          span(.page, "https://example\(page % 200).com/articles/\(page)?ref=feed", .front, title: "Article \(page) about things",
               app: "com.google.Chrome", at, at + step)
        }
        count += 1
      }
      let appStep = Self.activeMs / Int64(Self.appSpansPerDay)
      for index in 0..<Self.appSpansPerDay {
        let at = dayStart + Int64(index) * appStep
        let app = "com.app\(index % 25)"
        span(.app, app, .front, title: nil, app: app, at, at + appStep)
        count += 1
      }
      for index in 0..<Self.openSpansPerDay {
        let at = dayStart + Int64(index) * (Self.activeMs / Int64(Self.openSpansPerDay))
        let page = Int.random(in: 0..<5_000, using: &random)
        span(.page, "https://example\(page % 200).com/articles/\(page)?ref=feed", .open, title: "Article \(page) about things",
             app: "com.google.Chrome", at, min(at + 2 * 3_600_000, dayStart + Self.activeMs))
        count += 1
      }
    }
    database.exec("COMMIT;")
    BenchmarkEncryption.checkpointIfRequested(database.db)
    return count
  }

  @Test func storageAndPlanning() throws {
    let seeded = seed()
    report("seeded_spans", Double(seeded), "spans")
    let pageSize = database.count("PRAGMA page_size;")
    let pages = database.count("PRAGMA page_count;")
    report("db_bytes_per_span", Double(pageSize * pages) / Double(seeded), "bytes")

    // The recorder's writes: one span at a time, autocommit, strings mostly cached.
    let writeStart = Self.start + Int64(Self.days) * Self.dayMs
    var ids: [Int64] = []
    let writes = 2_000
    let insertTotal = milliseconds {
      for index in 0..<writes {
        let item = TimeWarpItem(kind: .page, value: "https://example\(index % 50).com/new/\(index % 400)", title: "New \(index % 400)")
        let start = TimeWarpSpanStart(item: item, source: .front, appBundleId: "com.google.Chrome", startMs: writeStart + Int64(index) * 1_000)
        if let id = DB.timeWarpInsert(start, endMs: start.startMs, isOpen: true, db: database.db, cache: database.cache) { ids.append(id) }
      }
    }
    report("open_span_write", insertTotal / Double(writes) * 1_000, "us")

    let middle = Self.start + 30 * Self.dayMs + 9 * 3_600_000
    for (name, length) in [("1_hour", Int64(3_600_000)), ("8_hours", Self.activeMs), ("1_day", Self.dayMs)] {
      var records: [TimeWarpSpanRecord] = []
      report("query_\(name)", median { records = DB.timeWarpSpans(fromMs: middle, toMs: middle + length, db: database.db) }, "ms")
      report("query_\(name)_rows", Double(records.count), "rows")
      for scope in TimeWarpScope.allCases {
        report("plan_\(name)_\(scope.rawValue)", median { _ = TimeWarpPlanner.plan(records: records, fromMs: middle, toMs: middle + length, scope: scope) }, "ms")
      }
      report("count_\(name)", median { _ = DB.countTimeWarpSpans(fromMs: middle, toMs: middle + length, db: database.db) }, "ms")
    }
    report("front_item_at", median { _ = DB.timeWarpSpans(fromMs: middle + 1_000, toMs: middle + 1_001, db: database.db) }, "ms")
    report("frame_end_lookup", median { _ = DB.timeWarpFrameEndMs(startedAtMs: middle, db: database.db) }, "ms")

    // Deletions add this work to every snapshot delete, range delete and retention run.
    report("delete_one_frame", milliseconds { try? DB.deleteTimeWarpRecords(fromMs: middle + 5_000, toMs: middle + 7_000, db: database.db) }, "ms")
    report("delete_1_hour", milliseconds { try? DB.deleteTimeWarpRecords(fromMs: middle + 3_600_000, toMs: middle + 7_200_000, db: database.db) }, "ms")
    report("delete_1_day", milliseconds { try? DB.deleteTimeWarpRecords(fromMs: middle + Self.dayMs, toMs: middle + 2 * Self.dayMs, db: database.db) }, "ms")
    report("retention_7_days", milliseconds { try? DB.purgeTimeWarpRecords(olderThan: Self.start + 7 * Self.dayMs, db: database.db) }, "ms")
    report("retention_nothing_expired", milliseconds { try? DB.purgeTimeWarpRecords(olderThan: Self.start + 7 * Self.dayMs, db: database.db) }, "ms")
  }
}
