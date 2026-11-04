import Darwin
import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// Benchmarks of app time on a large synthetic history: a year of 10 active hours a day, one capture
/// every 5 s (2.6M captures), switching among a day's 12 apps. Opt-in: run with
/// `TEST_RUNNER_TIMESCROLL_BENCHMARKS=1`. Timings are reported, not gated. Model generation isn't
/// covered: it depends on the model. With `TIMESCROLL_BENCHMARK_OUTPUT` set, results are also written
/// there as JSON.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARKS"] == "1"))
final class SummaryBenchmarks {
  private static let days = 365
  private static let dayMs: Int64 = 86_400_000
  private static let start = SummaryTestTime.ms(2025, 1, 1)
  private let database: SummaryTestDatabase

  init() throws {
    database = try SummaryTestDatabase()
  }

  private func report(_ name: String, _ value: Double, _ unit: String) {
    print(String(format: "BENCH %@ %.3f %@", name, value, unit))
    guard let path = ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARK_OUTPUT"] else { return }
    let line = "{\"name\":\"\(name)\",\"value\":\(value),\"unit\":\"\(unit)\"}\n"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
  }

  private func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
  }

  private func medianMs(runs: Int, _ body: () -> Void) -> Double {
    (0..<runs).map { _ in milliseconds(body) }.sorted()[runs / 2]
  }

  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
  }

  private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
  }

  private func databaseBytes() -> Int64 {
    Int64(database.count("PRAGMA page_count;")) * Int64(database.count("PRAGMA page_size;"))
  }

  private func insertHistory() {
    let db = database.db
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    sqlite3_prepare_v2(db, "INSERT INTO ts_snapshot(started_at_ms, app_bundle_id, app_name) VALUES(?, ?, ?);", -1, &stmt, nil)
    var random = SessionFixture.Random(seed: 11)
    let apps = (0..<40).map { "com.example.application\($0)" }
    database.exec("BEGIN;")
    for dayIndex in 0..<Self.days {
      let dayStart = Self.start + Int64(dayIndex) * Self.dayMs
      let todaysApps = (0..<12).map { _ in apps[random.int(apps.count)] }
      var time = dayStart + 8 * 3_600_000
      var app = todaysApps[0]
      for capture in 0..<7_200 {
        if capture % 24 == 0 { app = todaysApps[random.int(todaysApps.count)] }
        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, time)
        sqlite3_bind_text(stmt, 2, app, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, app, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        time += 5_000
      }
    }
    database.exec("COMMIT;")
  }

  @Test func yearOfHistory() throws {
    insertHistory()
    BenchmarkEncryption.checkpointIfRequested(database.db)
    let start = Self.start
    let end = start + Int64(Self.days) * Self.dayMs
    let calendar = SummaryTestTime.calendar()
    let bytesBefore = databaseBytes()
    let provider = AppTimeProvider(database: database, calendar: { calendar }, now: { end + Self.dayMs }, pauseBetweenBuilds: 0)
    let hour: Int64 = 3_600_000

    report("summaries.captures", Double(database.count("SELECT COUNT(*) FROM ts_snapshot;")), "count")

    // Reads that use only captures, with nothing built.
    report("summaries.read_1h_captures", medianMs(runs: 15) { _ = provider.report(fromMs: start + 9 * hour, toMs: start + 10 * hour) }, "ms")
    report("summaries.read_6h_captures", medianMs(runs: 15) { _ = provider.report(fromMs: start + 9 * hour, toMs: start + 15 * hour) }, "ms")
    let name = medianMs(runs: 15) { _ = try? database.read { DB.appTimeDisplayName(app: "com.example.application1", db: $0) } }
    report("summaries.display_name_lookup", name, "ms")

    // One day, built repeatedly: the first read rebuilds it each time.
    let oneDay = medianMs(runs: 15) {
      database.exec(DB.summaryInvalidationSQL(captureAt: "\(start + 200 * Self.dayMs + hour)"))
      _ = provider.report(fromMs: start + 200 * Self.dayMs, toMs: start + 201 * Self.dayMs)
    }
    report("summaries.build_and_read_one_day", oneDay, "ms")

    // Backfilling the rest, without the pause the app adds between days.
    let cpuBefore = cpuSeconds()
    let memoryBefore = footprintMB()
    var peakMemory = memoryBefore
    let backfill = milliseconds {
      for month in stride(from: 0, to: Self.days, by: 30) {
        let from = start + Int64(month) * Self.dayMs
        let done = DispatchSemaphore(value: 0)
        provider.backfill(fromMs: from, toMs: min(end, from + 30 * Self.dayMs)) { done.signal() }
        done.wait()
        peakMemory = max(peakMemory, footprintMB())
      }
    }
    report("summaries.backfill_year", backfill, "ms")
    report("summaries.backfill_year_cpu", cpuSeconds() - cpuBefore, "s")
    report("summaries.backfill_memory_growth_sampled", peakMemory - memoryBefore, "MB")

    // Reads with every day built.
    report("summaries.read_1d", medianMs(runs: 15) { _ = provider.report(fromMs: start + 100 * Self.dayMs, toMs: start + 101 * Self.dayMs) }, "ms")
    report("summaries.read_1d_midday_edges", medianMs(runs: 15) { _ = provider.report(fromMs: start + 100 * Self.dayMs + 6 * hour, toMs: start + 101 * Self.dayMs + 6 * hour) }, "ms")
    report("summaries.read_1w", medianMs(runs: 15) { _ = provider.report(fromMs: start + 100 * Self.dayMs, toMs: start + 107 * Self.dayMs) }, "ms")
    report("summaries.read_30d", medianMs(runs: 15) { _ = provider.report(fromMs: start + 100 * Self.dayMs, toMs: start + 130 * Self.dayMs) }, "ms")
    report("summaries.read_1y", medianMs(runs: 15) { _ = provider.report(fromMs: start, toMs: end) }, "ms")
    report("summaries.series_1w_hourly", medianMs(runs: 15) { _ = provider.series(fromMs: start + 100 * Self.dayMs, toMs: start + 107 * Self.dayMs, granularity: .hour) }, "ms")
    report("summaries.coverage_1y", medianMs(runs: 15) { _ = provider.coverage(fromMs: start, toMs: end) }, "ms")

    // The same year read straight from captures, for comparison.
    report("summaries.scan_1y_captures_no_rollups", medianMs(runs: 3) {
      if let source = try? database.read({ try DB.appTimeCaptures(fromMs: start, toMs: end, db: $0) }) {
        _ = AppTimeRollup.rows(captures: source.captures, nextCaptureMs: source.nextCaptureMs, bucketMs: Self.dayMs, limit: .max)
      }
    }, "ms")

    let rows = database.count("SELECT COUNT(*) FROM ts_app_time;")
    report("summaries.rows_per_day", Double(rows) / Double(Self.days), "count")
    report("summaries.rows_per_day_quarter_hour", Double(database.count("SELECT COUNT(*) FROM ts_app_time WHERE span = 0;")) / Double(Self.days), "count")
    let growth = databaseBytes() - bytesBefore
    report("summaries.disk_per_year", Double(growth) / 1_048_576, "MB")
    report("summaries.disk_per_day", Double(growth) / Double(Self.days) / 1024, "KB")

    // What a capture delete adds, on a day with all its rows.
    let deletion = "DELETE FROM ts_snapshot WHERE id = -1;"
    report("summaries.delete_baseline", medianMs(runs: 25) { database.exec(deletion) }, "ms")
    var dayIndex = 0
    report("summaries.delete_invalidation_added", medianMs(runs: 25) {
      database.exec(DB.summaryInvalidationSQL(captureAt: "\(start + Int64(dayIndex) * Self.dayMs + 9 * hour)"))
      dayIndex += 1
    }, "ms")
    report("summaries.retention_invalidation", milliseconds { database.exec(DB.summaryRetentionSQL(cutoffMs: start + 100 * Self.dayMs)) }, "ms")
  }

  /// A whole day as one session at the app's largest usual vectors: 5,760 screens, a third distinct.
  @Test func embeddingRepresentatives() throws {
    let dimension = 512
    let start = Self.start
    var state: UInt32 = 1
    database.exec("BEGIN;")
    for index in 0..<5_760 {
      let textId = Int64(index / 3)
      let vector = (0..<dimension).map { _ -> Float in
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(state >> 16) / 65_536 - 0.5
      }
      database.addScreen(at: start + Int64(index) * 5_000, textId: textId, vector: vector)
    }
    database.exec("COMMIT;")
    BenchmarkEncryption.checkpointIfRequested(database.db)
    let through = start + 5_760 * 5_000
    var found = SessionEmbeddingCandidates(candidates: [], embeddedTextCount: 0, screenTextCount: 0)
    report("summaries.embedding_read_long_session", medianMs(runs: 9) {
      found = DB.sessionEmbeddingCandidates(fromMs: start, throughMs: through, db: database.db)
    }, "ms")
    report("summaries.embedding_candidates_long_session", Double(found.candidates.count), "count")
    report("summaries.embedding_select_long_session", medianMs(runs: 9) {
      _ = EmbeddingRepresentativeSelector.select(found.candidates, count: 3)
    }, "ms")
    report("summaries.embedding_read_10_minutes", medianMs(runs: 9) {
      _ = DB.sessionEmbeddingCandidates(fromMs: start, throughMs: start + 600_000, db: database.db)
    }, "ms")
    #expect(found.embeddedTextCount == 1_920)
  }
}
