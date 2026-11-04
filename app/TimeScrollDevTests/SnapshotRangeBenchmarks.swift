import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// Counting and deleting ranges on 1M synthetic snapshots. Opt-in with
/// `TEST_RUNNER_TIMESCROLL_BENCHMARKS=1`. Timings are reported, not gated. With
/// `TIMESCROLL_BENCHMARK_OUTPUT` set, results are also written there as JSON.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARKS"] == "1"))
final class SnapshotRangeBenchmarks {
  private static let rows = 1_000_000
  private static let stepMs: Int64 = 5_000
  private static let start = SummaryTestTime.ms(2025, 1, 1)
  private static let dayMs: Int64 = 86_400_000
  private let database: SnapshotRangeTestDatabase

  init() throws {
    database = try SnapshotRangeTestDatabase()
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

  private func seed() {
    database.exec("BEGIN;")
    for index in 0..<Self.rows {
      let id = Int64(index + 1)
      let time = Self.start + Int64(index) * Self.stepMs
      let store = id / 3 + 1
      database.exec("""
      INSERT INTO ts_snapshot(id, started_at_ms, path, app_bundle_id, text_store_id) VALUES(\(id), \(time), '/m/\(id / 12).mov', 'com.app\(index % 12)', \(store));
      INSERT INTO ts_embedding(snapshot_id) VALUES(\(id));
      INSERT INTO ts_ocr_boxes(snapshot_id) VALUES(\(id));
      INSERT OR IGNORE INTO ts_text_store(id, content) VALUES(\(store), 'text');
      INSERT OR IGNORE INTO ts_session_sketch(text_store_id, sketch) VALUES(\(store), x'00');
      INSERT INTO ts_text_index(rowid, content) VALUES(\(id), 'some words on the screen');
      """)
    }
    database.exec("COMMIT;")
    BenchmarkEncryption.checkpointIfRequested(database.db)
  }

  @Test func countAndDelete() throws {
    // One segment per minute's 12 rows, like HEVC captures.
    seed()
    report("seeded_rows", Double(Self.rows), "rows")

    for (name, days) in [("count_1_day", Int64(1)), ("count_30_days", 30)] {
      let filter = SnapshotRangeFilter(fromMs: Self.start, toMs: Self.start + days * Self.dayMs)
      var runs: [Double] = []
      for _ in 0..<15 { runs.append(milliseconds { _ = DB.countSnapshots(matching: filter, db: database.db) }) }
      report(name, runs.sorted()[runs.count / 2], "ms")
    }
    let filtered = SnapshotRangeFilter(fromMs: Self.start, toMs: Self.start + 30 * Self.dayMs, appBundleIds: ["com.app3"])
    report("count_30_days_one_app", milliseconds { _ = DB.countSnapshots(matching: filtered, db: database.db) }, "ms")

    // One day: 17,280 rows.
    let filter = SnapshotRangeFilter(fromMs: Self.start, toMs: Self.start + Self.dayMs)
    var batches: [Double] = []
    var removed = 0
    while true {
      var batch = DB.SnapshotRangeBatch(removed: 0, files: [])
      let time = milliseconds {
        batch = (try? DB.deleteSnapshotBatch(matching: filter, limit: DB.snapshotRangeBatchSize, nowMs: Int64.max / 2, db: database.db)) ?? batch
      }
      guard batch.removed > 0 else { break }
      removed += batch.removed
      batches.append(time)
    }
    let sorted = batches.sorted()
    report("delete_day_rows", Double(removed), "rows")
    report("delete_day_total", batches.reduce(0, +), "ms")
    report("delete_batch_median", sorted[sorted.count / 2], "ms")
    report("delete_batch_max", sorted.last ?? 0, "ms")
    #expect(removed == 17_280)
    #expect(database.count("SELECT COUNT(*) FROM ts_snapshot;") == Self.rows - removed)

    reportCaptureWait()
  }

  /// Runs capture writes alone, then alongside deleting the next day, one batch at a time on one queue.
  private func reportCaptureWait() {
    let firstCapture = Self.start + Int64(Self.rows + 1) * Self.stepMs
    let idle = SnapshotRangeCaptureLoad(database: database, firstTimeMs: firstCapture)
    idle.start()
    Thread.sleep(forTimeInterval: 2)
    report("capture_write_idle_median", Self.percentile(idle.stop(), 0.5), "ms")

    let load = SnapshotRangeCaptureLoad(database: database, firstTimeMs: firstCapture + Self.dayMs)
    let filter = SnapshotRangeFilter(fromMs: Self.start + Self.dayMs, toMs: Self.start + 2 * Self.dayMs)
    load.start()
    let deleteBegan = DispatchTime.now().uptimeNanoseconds
    var removed = 0
    while true {
      let batch = load.writer.sync {
        (try? DB.deleteSnapshotBatch(matching: filter, limit: DB.snapshotRangeBatchSize, nowMs: Int64.max / 2, db: database.db))
      }
      guard let batch, batch.removed > 0 else { break }
      removed += batch.removed
    }
    report("capture_load_delete_wall", Double(DispatchTime.now().uptimeNanoseconds - deleteBegan) / 1e6, "ms")
    let waits = load.stop()
    report("capture_write_during_delete_median", Self.percentile(waits, 0.5), "ms")
    report("capture_write_during_delete_p99", Self.percentile(waits, 0.99), "ms")
    report("capture_write_during_delete_max", waits.max() ?? 0, "ms")
    report("capture_write_during_delete_longest_queued", load.longestQueuedMs, "ms")
    report("capture_write_during_delete_longest_own", load.longestOwnMs, "ms")
    report("capture_writes_during_delete", Double(waits.count), "writes")
    report("capture_load_batches", Double(removed / DB.snapshotRangeBatchSize), "batches")
    #expect(removed == 17_280)
  }

  private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
  }
}
