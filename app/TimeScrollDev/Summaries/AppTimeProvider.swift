import Foundation

/// Answers app time questions for any range. Days are built the first time a read needs them;
/// nothing runs on the capture path. Calls block, so make them off the main thread. They return nil
/// when the database is unavailable (vault locked).
final class AppTimeProvider: @unchecked Sendable {
  static let shared = AppTimeProvider(database: SharedSummaryDatabase())

  enum DayState: Equatable {
    case built
    /// Over and not built yet; the next read that needs it builds it.
    case pending
    /// Can still change, so reads use its captures.
    case inProgress
    /// Ended before the earliest remaining capture.
    case noCaptures
  }

  struct DayCoverage: Equatable {
    let day: SessionDayPlanner.Day
    let state: DayState
  }

  private let database: SummaryDatabase
  private let calendar: () -> Calendar
  private let now: () -> Int64
  private let pauseBetweenBuilds: TimeInterval
  private let queue = DispatchQueue(label: "TimeScroll.AppTime", qos: .utility)

  init(database: SummaryDatabase,
       calendar: @escaping () -> Calendar = { .current },
       now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
       pauseBetweenBuilds: TimeInterval = 0.01) {
    self.database = database
    self.calendar = calendar
    self.now = now
    self.pauseBetweenBuilds = pauseBetweenBuilds
  }

  func resolve(fromMs: Int64, toMs: Int64) -> ResolvedSummaryRange {
    SummaryRangeResolver.resolve(fromMs: fromMs, toMs: toMs, calendar: calendar())
  }

  /// Totals and the top `topK` apps, with the rest as "other".
  func report(fromMs: Int64, toMs: Int64, topK: Int = AppTimeRollup.maxAppsPerBucket) -> AppTimeReport? {
    queue.sync {
      let range = resolve(fromMs: fromMs, toMs: toMs)
      guard let rows = try? rows(range: range, app: nil, splitWholeDays: false) else { return nil }
      var report = AppTimeReport(range: range, rows: rows, topK: topK)
      let apps = report.topApps.map(\.app)
      if let names = try? database.read({ db in apps.map { DB.appTimeDisplayName(app: $0, db: db) } }) {
        for index in report.topApps.indices { report.topApps[index].name = names[index] }
      }
      return report
    }
  }

  /// Time in one app. Approximate if the app fell outside the limit in some buckets.
  func appTime(fromMs: Int64, toMs: Int64, app: String) -> Int64? {
    queue.sync {
      let range = resolve(fromMs: fromMs, toMs: toMs)
      return (try? rows(range: range, app: app, splitWholeDays: false))?.reduce(0) { $0 + $1.dwellMs }
    }
  }

  func series(fromMs: Int64, toMs: Int64, granularity: AppTimeSeries.Granularity, app: String? = nil) -> [AppTimeSeries.Point]? {
    queue.sync {
      let range = resolve(fromMs: fromMs, toMs: toMs)
      let effective = AppTimeSeries.effective(granularity, precision: range.precision)
      guard let rows = try? rows(range: range, app: app, splitWholeDays: effective != .day) else { return nil }
      return AppTimeSeries.points(rows: rows, granularity: effective, calendar: calendar())
    }
  }

  func coverage(fromMs: Int64, toMs: Int64) -> [DayCoverage]? {
    queue.sync {
      guard toMs > fromMs else { return [] }
      let calendar = calendar()
      let nowMs = now()
      let days = SessionDayPlanner.days(from: fromMs, to: toMs - 1, calendar: calendar)
      guard let (built, earliest) = try? database.read({ db in
        (try DB.builtAppTimeDays(fromMs: fromMs, toMs: toMs, db: db), DB.earliestScreenCaptureMs(db: db))
      }) else { return nil }
      return days.map { day in
        if !SummaryRangeResolver.isSettled(day, nowMs: nowMs) { return DayCoverage(day: day, state: .inProgress) }
        if built.contains(day.startMs) { return DayCoverage(day: day, state: .built) }
        if let earliest, day.endMs > earliest { return DayCoverage(day: day, state: .pending) }
        return DayCoverage(day: day, state: .noCaptures)
      }
    }
  }

  /// Builds a range's missing days in the background.
  func backfill(fromMs: Int64, toMs: Int64, completion: (@Sendable () -> Void)? = nil) {
    queue.async { [self] in
      if toMs > fromMs {
        let days = SessionDayPlanner.days(from: fromMs, to: toMs - 1, calendar: calendar())
        _ = try? ensureBuilt(days: days)
      }
      completion?()
    }
  }

  // MARK: - On `queue`

  private func rows(range: ResolvedSummaryRange, app: String?, splitWholeDays: Bool) throws -> [AppTimeRow] {
    let pieces = SummaryRangeResolver.pieces(for: range, nowMs: now(), calendar: calendar(), splitWholeDays: splitWholeDays)
    // A delete between building and reading would undercount, so read again if one happened.
    var attempt = 0
    while true {
      attempt += 1
      let before = try database.read { DB.summaryInvalidationCount(db: $0) }
      let built = try ensureBuilt(days: pieces.compactMap(\.day))
      let (rows, after) = try database.read { db in
        (try read(pieces: pieces, built: built, range: range, app: app, db: db), DB.summaryInvalidationCount(db: db))
      }
      if before == after || attempt >= 3 { return rows }
    }
  }

  /// Returns the days that are built; a day whose build lost a race is left to be read from captures.
  private func ensureBuilt(days: [SessionDayPlanner.Day]) throws -> Set<Int64> {
    let settled = days.filter { SummaryRangeResolver.isSettled($0, nowMs: now()) }
    guard let first = settled.first, let last = settled.last else { return [] }
    var built = try database.read { try DB.builtAppTimeDays(fromMs: first.startMs, toMs: last.endMs, db: $0) }
    for day in settled where !built.contains(day.startMs) {
      if try build(day) { built.insert(day.startMs) }
      if pauseBetweenBuilds > 0 { Thread.sleep(forTimeInterval: pauseBetweenBuilds) }
    }
    return built
  }

  private func build(_ day: SessionDayPlanner.Day) throws -> Bool {
    let (expected, source) = try database.read { db in
      (DB.summaryInvalidationCount(db: db), try DB.appTimeCaptures(fromMs: day.startMs, toMs: day.endMs, db: db))
    }
    let rollup = AppTimeRollup.day(captures: source.captures, nextCaptureMs: source.nextCaptureMs, dayStartMs: day.startMs)
    let computedAt = now()
    return try database.write { db in
      try DB.replaceAppTimeDay(day, rollup: rollup, computedAtMs: computedAt, expectedInvalidations: expected, db: db)
    }
  }

  private func read(pieces: [AppTimePiece], built: Set<Int64>, range: ResolvedSummaryRange, app: String?, db: OpaquePointer) throws -> [AppTimeRow] {
    var rows: [AppTimeRow] = []
    // Adjacent whole days read as one query, so a long range isn't one statement per day.
    var wholeDays: (fromMs: Int64, toMs: Int64)?
    func flushWholeDays() throws {
      guard let open = wholeDays else { return }
      rows += try DB.appTimeRows(span: .day, fromMs: open.fromMs, toMs: open.toMs, app: app, db: db)
      wholeDays = nil
    }
    let capturesBucket = range.precision == .exact ? Int64(60_000) : AppTimeRollup.quarterHourMs
    func readCaptures(fromMs: Int64, toMs: Int64) throws {
      let source = try DB.appTimeCaptures(fromMs: fromMs, toMs: toMs, db: db)
      let all = AppTimeRollup.rows(captures: source.captures, nextCaptureMs: source.nextCaptureMs, bucketMs: capturesBucket, limit: .max)
      rows += app.map { wanted in all.filter { $0.app == wanted } } ?? all
    }

    for piece in pieces {
      switch piece {
      case .wholeDay(let day) where built.contains(day.startMs):
        if let open = wholeDays, open.toMs == day.startMs {
          wholeDays = (open.fromMs, day.endMs)
        } else {
          try flushWholeDays()
          wholeDays = (day.startMs, day.endMs)
        }
      case .wholeDay(let day):
        try flushWholeDays()
        try readCaptures(fromMs: day.startMs, toMs: day.endMs)
      case .quarterHours(let day, let fromMs, let toMs):
        try flushWholeDays()
        if built.contains(day.startMs) {
          rows += try DB.appTimeRows(span: .quarterHour, fromMs: fromMs, toMs: toMs, app: app, db: db)
        } else {
          try readCaptures(fromMs: fromMs, toMs: toMs)
        }
      case .captures(let fromMs, let toMs):
        try flushWholeDays()
        try readCaptures(fromMs: fromMs, toMs: toMs)
      }
    }
    try flushWholeDays()
    return rows
  }
}
