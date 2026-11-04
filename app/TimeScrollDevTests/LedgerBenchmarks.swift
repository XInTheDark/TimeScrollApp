import Foundation
import Testing
@testable import TimeScroll

/// Ledgers on a year of 30 sessions a day, each with 3 screens of about 4 KB. Sessions and texts come
/// from memory, so this leaves out computing sessions and decompressing text. Opt-in, like
/// `SummaryBenchmarks`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARKS"] == "1"))
final class LedgerBenchmarks {
  private final class NoModel: SummaryTextGenerating, @unchecked Sendable {
    var promptBytes = 0
    func readiness(model: String) -> SummaryModelReadiness { .ready(contextTokens: nil) }
    func generate(model: String, system: String, prompt: String, contextTokens: Int, maxOutputTokens: Int) -> String? {
      promptBytes = prompt.utf8.count
      return "A summary."
    }
    func cancel() {}
    func unload(model: String) {}
  }

  private static let days = 365
  private static let dayMs: Int64 = 86_400_000
  private static let start = SummaryTestTime.ms(2025, 1, 1)

  private func report(_ name: String, _ value: Double, _ unit: String) {
    print(String(format: "BENCH %@ %.3f %@", name, value, unit))
    guard let path = ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARK_OUTPUT"] else { return }
    let line = Data("{\"name\":\"\(name)\",\"value\":\(value),\"unit\":\"\(unit)\"}\n".utf8)
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      FileManager.default.createFile(atPath: path, contents: line)
    }
  }

  private func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
  }

  @Test func yearOfLedgers() throws {
    let database = try SummaryTestDatabase()
    let screen = (0..<80).map { "line \($0) of the screen with file\($0).swift and some ordinary words" }.joined(separator: "\n")
    var sessionsByDay: [Int64: [ActivitySession]] = [:]
    for day in 0..<Self.days {
      let dayStart = Self.start + Int64(day) * Self.dayMs
      sessionsByDay[dayStart] = (0..<30).map { index in
        let id = Int64(day * 100 + index)
        let textIds = (0..<3).map { id * 10 + Int64($0) }
        for textId in textIds { database.storedTexts[textId] = "\(textId) \(screen)" }
        let startMs = dayStart + Int64(index) * 1_200_000
        return ActivitySession(id: id, startMs: startMs, endMs: startMs + 900_000, snapshotCount: 180,
                               apps: [.init(bundleId: "com.a\(index % 6)", name: "App \(index % 6)", ms: 900_000)],
                               keywords: (0..<5).map { "word\(day % 40)x\(index + $0)" }, representativeTextIds: textIds)
      }
    }
    database.addCapture(at: Self.start + 1, app: "com.a0", name: "App 0")
    let nowMs = Self.start + Int64(Self.days + 30) * Self.dayMs
    let store = ActivityLedgerStore(database: database, sessionsForDay: { sessionsByDay[$0.startMs] }, now: { nowMs })
    let calendar = SummaryTestTime.calendar()
    let end = Self.start + Int64(Self.days) * Self.dayMs
    let days = SessionDayPlanner.days(from: Self.start, to: end - 1, calendar: calendar)
    let before = database.count("PRAGMA page_count;")

    var ledgers: [ActivityLedger] = []
    let cold = milliseconds { ledgers = store.ledgers(days: days, fromMs: Self.start, toMs: end, shouldContinue: { true }) ?? [] }
    #expect(ledgers.count == Self.days)
    report("ledger.build_year", cold, "ms")
    report("ledger.build_day", cold / Double(Self.days), "ms")
    let warm = milliseconds { ledgers = store.ledgers(days: days, fromMs: Self.start, toMs: end, shouldContinue: { true }) ?? [] }
    report("ledger.read_year", warm, "ms")
    let bytes = (database.count("PRAGMA page_count;") - before) * database.count("PRAGMA page_size;")
    report("ledger.disk_year", Double(bytes) / 1_048_576, "MB")

    var merged: ActivityLedger?
    report("ledger.merge_year", milliseconds { merged = ActivityLedgerMerger.merge(ledgers, startMs: Self.start, endMs: end) }, "ms")
    #expect(merged?.activeMs ?? 0 > 0)

    let buckets = SummaryBuckets.buckets(fromMs: Self.start, toMs: end, calendar: calendar)
    var rendered = ""
    let briefing = milliseconds {
      let sections = buckets.map { bucket in
        RangeBriefing.Section(label: "x", ledger: ActivityLedgerMerger.merge(ledgers.filter { bucket.contains($0.startMs) }, startMs: bucket.lowerBound, endMs: bucket.upperBound), summaries: [])
      }
      rendered = RangeBriefing.render(sections, budgetBytes: 19_000)
    }
    report("ledger.briefing_year", briefing, "ms")
    report("ledger.briefing_bytes", Double(rendered.utf8.count), "bytes")

    let invalidate = milliseconds { database.exec(DB.summaryInvalidationSQL(capturesFromMs: Self.start + 3_600_000, throughMs: Self.start + 3_600_000)) }
    report("ledger.delete_added", invalidate, "ms")
  }
}
