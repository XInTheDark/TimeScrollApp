import AppKit
import Foundation
import SQLCipher
import Testing
@testable import TimeScroll

/// Benchmarks of session segmentation on a large synthetic history (120k screen captures, about a
/// week at one capture every 5 s). Opt-in: run with `TEST_RUNNER_TIMESCROLL_BENCHMARKS=1`. Timings
/// are reported, not gated; the segmenter's work count is deterministic and gated.
/// With `TIMESCROLL_BENCHMARK_OUTPUT` set, results are also written there as JSON.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARKS"] == "1"))
final class SessionBenchmarks {
  private static let captureCount = 120_000
  private static let dayMs: Int64 = 86_400_000

  private let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("session-bench-\(UUID().uuidString).sqlite")
  private var db: OpaquePointer!

  deinit {
    if db != nil { sqlite3_close(db) }
    try? FileManager.default.removeItem(at: url)
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

  /// Median wall time of `runs` calls, in milliseconds.
  private func medianMs(runs: Int, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    for _ in 0..<runs {
      let start = DispatchTime.now().uptimeNanoseconds
      body()
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return samples.sorted()[samples.count / 2]
  }

  /// A week of work: half-hour stretches on one of 12 tasks across 2–3 apps, with idle breaks.
  private static func week() -> SessionFixture {
    var fixture = SessionFixture()
    var random = SessionFixture.Random(seed: 7)
    let topics = (0..<12).map { SessionFixture.topic("task\($0)") }
    var time: Int64 = 1_760_000_000_000
    while fixture.captures.count < captureCount {
      let task = random.int(topics.count)
      let apps = (0..<(2 + random.int(2))).map { Int32((task + $0 * 5) % 9) }
      fixture.work(topic: topics[task], apps: apps, minutes: Double(10 + random.int(50)), startMs: time)
      time = fixture.captures.last!.timeMs + 5_000 + (random.int(4) == 0 ? Int64(20 + random.int(90)) * 60_000 : 0)
    }
    fixture.captures.removeLast(fixture.captures.count - captureCount)
    return fixture
  }

  /// A long OCR text (about 450 words, 3 KB) with numbers, paths and punctuation.
  private static let longText: String = {
    var random = SessionFixture.Random(seed: 1)
    let words = SessionFixture.topic("ocr", size: 400) + ["v2.3.1", "/Users/me/project", "2026-10-31", "12:45", "#4521", "—", "∑"]
    return (0..<450).map { _ in words[random.int(words.count)] }.joined(separator: " ")
  }()

  @Test func sketchPerCapture() {
    let text = Self.longText
    var sink = 0
    let perText = medianMs(runs: 9) {
      for _ in 0..<200 { sink &+= SessionTextSketch.make(from: text).count }
    } / 200
    #expect(sink > 0)
    report("sessions.sketch_make_3kb_text", perText * 1000, "us")
  }

  @Test func segmentationScalesLinearly() {
    let fixture = Self.week()
    let (samples, sketches) = fixture.samples()
    let parameters = SessionSegmenter.Parameters(sensitivity: .balanced)
    var day = SessionFixture()
    day.captures = Array(fixture.captures.prefix(17_280))
    let (daySamples, daySketches) = day.samples()

    var dayResult = SessionSegmenter.Result(ranges: [], work: 0)
    let dayMs = medianMs(runs: 5) { dayResult = SessionSegmenter.segment(samples: daySamples, sketches: daySketches, parameters: parameters) }
    var weekResult = SessionSegmenter.Result(ranges: [], work: 0)
    let weekMs = medianMs(runs: 3) { weekResult = SessionSegmenter.segment(samples: samples, sketches: sketches, parameters: parameters) }
    report("sessions.segment_day_17k", dayMs, "ms")
    report("sessions.segment_week_120k", weekMs, "ms")
    report("sessions.segment_week_sessions", Double(weekResult.ranges.count), "count")
    report("sessions.segment_week_work_per_sample", Double(weekResult.work) / Double(samples.count), "ops")
    // Linear: work per sample stays flat from one day to a week.
    let dayPerSample = Double(dayResult.work) / Double(daySamples.count)
    let weekPerSample = Double(weekResult.work) / Double(samples.count)
    #expect(weekPerSample < dayPerSample * 1.5)

  }

  @Test func databaseDayReadAndPipeline() throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "bench", code: 1) }
    db = handle
    exec("""
    CREATE TABLE ts_snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at_ms INTEGER NOT NULL, app_bundle_id TEXT, app_name TEXT,
                              text_ref_id INTEGER, text_store_id INTEGER, capture_kind TEXT NOT NULL DEFAULT 'screen');
    CREATE INDEX idx_ts_snapshot_started_at_ms ON ts_snapshot(started_at_ms DESC);
    CREATE TABLE ts_text_store (id INTEGER PRIMARY KEY AUTOINCREMENT, sha256 TEXT NOT NULL UNIQUE, codec TEXT NOT NULL,
                                original_bytes INTEGER NOT NULL, data BLOB NOT NULL);
    """)
    DB.createSessionSketchTableIfNeeded(db: db)
    DB.createActivitySessionTablesIfNeeded(db: db)

    let fixture = Self.week()
    let filler = Data(repeating: 0x61, count: 1_500)   // compressed text the sample read must not touch
    exec("BEGIN;")
    var lastText = ""
    var lastStoreId: Int64 = 0
    var insertSnapshot: OpaquePointer?
    var insertText: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO ts_snapshot(started_at_ms, app_bundle_id, app_name, text_ref_id, text_store_id) VALUES(?,?,?,?,?);", -1, &insertSnapshot, nil)
    sqlite3_prepare_v2(db, "INSERT INTO ts_text_store(sha256, codec, original_bytes, data) VALUES(?, 'identity', 1, ?);", -1, &insertText, nil)
    for (index, capture) in fixture.captures.enumerated() {
      var textRef: Int64?
      var storeId: Int64?
      if !capture.text.isEmpty {
        if capture.text == lastText {
          textRef = Int64(index)   // the previous snapshot holds the text
        } else {
          sqlite3_reset(insertText)
          sqlite3_bind_text(insertText, 1, "h\(index)", -1, SQLITE_TRANSIENT)
          _ = filler.withUnsafeBytes { sqlite3_bind_blob(insertText, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
          _ = sqlite3_step(insertText)
          lastStoreId = sqlite3_last_insert_rowid(db)
          lastText = capture.text
          DB.writeSessionSketch(SessionTextSketch.make(from: capture.text), textStoreId: lastStoreId, db: db)
        }
        storeId = textRef == nil ? lastStoreId : nil
      }
      sqlite3_reset(insertSnapshot)
      sqlite3_bind_int64(insertSnapshot, 1, capture.timeMs)
      sqlite3_bind_text(insertSnapshot, 2, "com.app\(capture.app)", -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(insertSnapshot, 3, "App \(capture.app)", -1, SQLITE_TRANSIENT)
      if let textRef { sqlite3_bind_int64(insertSnapshot, 4, textRef) } else { sqlite3_bind_null(insertSnapshot, 4) }
      if let storeId { sqlite3_bind_int64(insertSnapshot, 5, storeId) } else { sqlite3_bind_null(insertSnapshot, 5) }
      _ = sqlite3_step(insertSnapshot)
    }
    sqlite3_finalize(insertSnapshot)
    sqlite3_finalize(insertText)
    exec("COMMIT;")

    let first = fixture.captures[0].timeMs
    let day = SessionDayPlanner.day(containing: first + 2 * Self.dayMs, calendar: .current)
    var rows: [SessionSampleRow] = []
    let readMs = medianMs(runs: 7) { rows = (try? DB.sessionSampleRows(fromMs: day.windowStartMs, toMs: day.windowEndMs, db: db)) ?? [] }
    let fingerprintMs = medianMs(runs: 7) { _ = try? DB.sessionDayFingerprint(fromMs: day.windowStartMs, toMs: day.windowEndMs, db: db) }
    #expect(rows.count > 10_000)
    report("sessions.db_day_rows", Double(rows.count), "count")
    report("sessions.db_read_day_samples", readMs, "ms")
    report("sessions.db_day_fingerprint", fingerprintMs, "ms")

    let parameters = SessionSegmenter.Parameters(sensitivity: .balanced)
    var input = SessionInput(rows: rows)
    report("sessions.day_input", medianMs(runs: 5) { input = SessionInput(rows: rows) }, "ms")
    var ranges: [Range<Int>] = []
    report("sessions.day_segment", medianMs(runs: 5) {
      ranges = SessionSegmenter.segment(samples: input.samples, sketches: input.sketches, parameters: parameters).ranges
    }, "ms")
    report("sessions.day_summarize", medianMs(runs: 5) {
      _ = SessionSummarizer.summarize(ranges: ranges, samples: input.samples, snapshotIds: rows.map(\.snapshotId),
                                      apps: input.apps, sketches: input.sketches, parameters: parameters)
    }, "ms")
    report("sessions.day_distinct_texts", Double(input.sketches.count), "count")
    var stored = 0
    let pipelineMs = medianMs(runs: 5) {
      let input = SessionInput(rows: rows)
      let ranges = SessionSegmenter.segment(samples: input.samples, sketches: input.sketches, parameters: parameters).ranges
      let drafts = SessionSummarizer.summarize(ranges: ranges, samples: input.samples, snapshotIds: rows.map(\.snapshotId),
                                               apps: input.apps, sketches: input.sketches, parameters: parameters)
      let sessions = drafts.map(\.session).filter { day.owns($0) }
      let record = SessionDayRecord(dayStartMs: day.startMs, windowStartMs: day.windowStartMs, windowEndMs: day.windowEndMs,
                                    params: "v1|balanced", fingerprint: input.fingerprint, computedAtMs: 0)
      try? DB.replaceActivitySessions(sessions, record: record, db: db)
      stored = sessions.count
    }
    #expect(stored > 0)
    report("sessions.day_pipeline_without_labels", pipelineMs, "ms")
    let storedReadMs = medianMs(runs: 7) { _ = DB.activitySessions(dayStartMs: day.startMs, db: db) }
    report("sessions.db_read_stored_day", storedReadMs, "ms")

    // The per-capture hook: a lookup for a known text, and lookup plus insert for a new one.
    let knownMs = medianMs(runs: 5) {
      for _ in 0..<500 { DB.storeSessionSketchIfMissing(textStoreId: 1, content: Self.longText, db: db) }
    } / 500
    var nextId: Int64 = 10_000_000
    let newMs = medianMs(runs: 5) {
      for _ in 0..<200 {
        nextId += 1
        DB.storeSessionSketchIfMissing(textStoreId: nextId, content: Self.longText, db: db)
      }
    } / 200
    report("sessions.capture_hook_known_text", knownMs * 1000, "us")
    report("sessions.capture_hook_new_text", newMs * 1000, "us")
  }

  @MainActor
  @Test func timelineBandPlanAndSearchGrouping() {
    var random = SessionFixture.Random(seed: 3)
    var start: Int64 = 0
    let sessions = (0..<2_000).map { index -> ActivitySession in
      let length = Int64(5 + random.int(60)) * 60_000
      defer { start += length + 60_000 }
      return ActivitySession(id: Int64(index), startMs: start, endMs: start + length, snapshotCount: 100,
                             apps: [.init(bundleId: "com.app", name: "Xcode", ms: length)],
                             keywords: ["timeline", "session\(index)", "planner"])
    }
    let planMs = medianMs(runs: 5) {
      _ = TimelineSessionBandPlanner.plan(sessions: sessions, x: { CGFloat($0) / 60_000 }, fillsGaps: true,
                                          labelWidth: TimelineSessionBandRenderer.labelWidth)
    }
    report("sessions.band_plan_2000_sessions", planMs, "ms")
    // While pinching, widths come from the view's cache.
    var widths: [String: CGFloat] = [:]
    let cachedPlanMs = medianMs(runs: 5) {
      _ = TimelineSessionBandPlanner.plan(sessions: sessions, x: { CGFloat($0) / 60_000 }, fillsGaps: true, labelWidth: { text in
        if let width = widths[text] { return width }
        let width = TimelineSessionBandRenderer.labelWidth(text)
        widths[text] = width
        return width
      })
    }
    report("sessions.band_plan_2000_sessions_cached_widths", cachedPlanMs, "ms")

    let hits = (0..<SearchSessionPager.maxPool).map { index in
      SearchSessionGrouperTests.hit(Int64(index), at: Int64(random.int(Int(start))))
    }
    let groupMs = medianMs(runs: 7) { _ = SearchSessionGrouper.group(hits, sessions: sessions) }
    report("sessions.group_4000_hits", groupMs, "ms")
  }

  private func exec(_ sql: String) {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    #expect(result == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
  }
}
