import Foundation

/// Computes, stores and caches activity sessions, one local day at a time.
///
/// A day is computed once and stored. Later requests reuse it: days that ended well before they
/// were computed (and whose captures all had sketches) are trusted as stored; recent days are
/// checked against a cheap fingerprint of their captures and recomputed only when it changed, and
/// the live day at most every `liveRecheckMs`. All work runs on one serial queue, off the main thread.
final class ActivitySessionProvider: @unchecked Sendable {
  static let shared = ActivitySessionProvider()
  static let algorithmVersion = 2

  /// How often a day that can still change is re-checked against its captures.
  static let liveRecheckMs: Int64 = 30_000
  /// A day computed this long after its window closed has all its OCR text.
  static let settleDelayMs: Int64 = 10 * 60_000

  private let queue = DispatchQueue(label: "TimeScroll.ActivitySessions", qos: .userInitiated)
  private let queueKey = DispatchSpecificKey<Bool>()
  private struct CachedDay {
    let params: String
    let sessions: [ActivitySession]
    let checkedAtMs: Int64
    let settled: Bool
  }
  private var memory: [Int64: CachedDay] = [:]

  private init() { queue.setSpecific(key: queueKey, value: true) }

  static func params(for sensitivity: SessionSensitivity) -> String { "v\(algorithmVersion)|\(sensitivity.rawValue)" }

  /// Sessions overlapping `[fromMs, toMs]`, oldest first; nil when the database is unavailable
  /// (vault locked). Delivered on the main queue.
  func sessions(fromMs: Int64, toMs: Int64, sensitivity: SessionSensitivity,
                completion: @escaping ([ActivitySession]?) -> Void) {
    queue.async { [self] in
      let days = SessionDayPlanner.days(from: fromMs, to: toMs, calendar: .current)
      let result = sessions(for: days, sensitivity: sensitivity)?.filter { $0.endMs >= fromMs && $0.startMs <= toMs }
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// Sessions of every day containing one of `times`, oldest first. Blocks; call off the main thread.
  func sessions(coveringTimes times: [Int64], sensitivity: SessionSensitivity) -> [ActivitySession]? {
    let days = SessionDayPlanner.days(containing: times, calendar: .current)
    if DispatchQueue.getSpecific(key: queueKey) == true { return sessions(for: days, sensitivity: sensitivity) }
    return queue.sync { sessions(for: days, sensitivity: sensitivity) }
  }

  /// Drops cached sessions (their labels are screen text); called when the vault locks.
  func clearMemory() {
    queue.async { [self] in memory.removeAll() }
  }

  // MARK: - Per day (on `queue`)

  private func sessions(for days: [SessionDayPlanner.Day], sensitivity: SessionSensitivity) -> [ActivitySession]? {
    var all: [ActivitySession] = []
    for day in days {
      guard let sessions = try? sessions(for: day, sensitivity: sensitivity) else { return nil }
      all += sessions
    }
    return SessionDayPlanner.combine(all)
  }

  private func sessions(for day: SessionDayPlanner.Day, sensitivity: SessionSensitivity) throws -> [ActivitySession] {
    let params = Self.params(for: sensitivity)
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    if let cached = memory[day.startMs], cached.params == params,
       cached.settled || nowMs - cached.checkedAtMs < Self.liveRecheckMs {
      return cached.sessions
    }

    let db = DB.shared
    if let record = try db.sessionDayRecord(dayStartMs: day.startMs), record.params == params {
      if isSettled(record) {
        return remember(try db.activitySessions(dayStartMs: day.startMs), day: day, params: params, nowMs: nowMs, settled: true)
      }
      let fingerprint = try db.sessionDayFingerprint(fromMs: day.windowStartMs, toMs: day.windowEndMs)
      if fingerprint == record.fingerprint {
        return remember(try db.activitySessions(dayStartMs: day.startMs), day: day, params: params, nowMs: nowMs, settled: false)
      }
    }

    let computed = try compute(day: day, sensitivity: sensitivity, nowMs: nowMs)
    try db.replaceActivitySessions(computed.sessions, record: computed.record)
    return remember(computed.sessions, day: day, params: params, nowMs: nowMs, settled: isSettled(computed.record))
  }

  private func isSettled(_ record: SessionDayRecord) -> Bool {
    record.fingerprint.isComplete && record.computedAtMs >= record.windowEndMs + Self.settleDelayMs
  }

  private func remember(_ sessions: [ActivitySession], day: SessionDayPlanner.Day, params: String,
                        nowMs: Int64, settled: Bool) -> [ActivitySession] {
    memory[day.startMs] = CachedDay(params: params, sessions: sessions, checkedAtMs: nowMs, settled: settled)
    return sessions
  }

  private func compute(day: SessionDayPlanner.Day, sensitivity: SessionSensitivity,
                       nowMs: Int64) throws -> (sessions: [ActivitySession], record: SessionDayRecord) {
    let db = DB.shared
    var rows = try db.sessionSampleRows(fromMs: day.windowStartMs, toMs: day.windowEndMs)
    let missing = Set(rows.compactMap { $0.sketch == nil ? $0.textStoreId : nil })
    if !missing.isEmpty {
      let filled = try db.fillSessionSketches(textStoreIds: missing.sorted())
      rows = rows.map { row in
        guard row.sketch == nil, let id = row.textStoreId, let sketch = filled[id] else { return row }
        return SessionSampleRow(snapshotId: row.snapshotId, timeMs: row.timeMs, appBundleId: row.appBundleId,
                                appName: row.appName, textStoreId: id, sketch: sketch)
      }
    }

    let input = SessionInput(rows: rows)
    let parameters = SessionSegmenter.Parameters(sensitivity: sensitivity)
    let ranges = SessionSegmenter.segment(samples: input.samples, sketches: input.sketches, parameters: parameters).ranges
    let drafts = SessionSummarizer.summarize(ranges: ranges, samples: input.samples, snapshotIds: rows.map(\.snapshotId),
                                             apps: input.apps, sketches: input.sketches, parameters: parameters)
      .filter { day.owns($0.session) }

    let textIds = Set(drafts.flatMap { $0.representativeSketches.map { input.sketchTextStoreIds[Int($0)] } })
    let texts = try db.sessionTexts(textStoreIds: Array(textIds))
    let sessions = drafts.map { draft in
      let representativeTexts = draft.representativeSketches.compactMap { texts[input.sketchTextStoreIds[Int($0)]] }
      let session = draft.session
      return ActivitySession(id: session.id, startMs: session.startMs, endMs: session.endMs,
                             snapshotCount: session.snapshotCount, apps: session.apps,
                             keywords: SessionLabeler.keywords(for: draft.keywordHashes, texts: representativeTexts))
    }

    let record = SessionDayRecord(dayStartMs: day.startMs, windowStartMs: day.windowStartMs, windowEndMs: day.windowEndMs,
                                  params: Self.params(for: sensitivity), fingerprint: input.fingerprint, computedAtMs: nowMs)
    return (sessions, record)
  }
}
