import Foundation

/// Ledgers for days and parts of days. Finished days are built once and stored; the rest are built each
/// time. A ledger that can't be stored is still used.
final class ActivityLedgerStore: @unchecked Sendable {
  private let database: SummaryDatabase
  private let sessionsForDay: (SessionDayPlanner.Day) -> [ActivitySession]?
  private let now: () -> Int64

  init(database: SummaryDatabase,
       sessionsForDay: @escaping (SessionDayPlanner.Day) -> [ActivitySession]?,
       now: @escaping () -> Int64) {
    self.database = database
    self.sessionsForDay = sessionsForDay
    self.now = now
  }

  /// One ledger per day, clipped to `[fromMs, toMs)`, oldest first. Nil when the vault is locked or
  /// `shouldContinue` turns false.
  func ledgers(days: [SessionDayPlanner.Day], fromMs: Int64, toMs: Int64, shouldContinue: () -> Bool) -> [ActivityLedger]? {
    guard let first = days.first, let last = days.last else { return [] }
    guard let (expected, stored) = try? database.read({ db in
      (DB.summaryInvalidationCount(db: db), DB.activityLedgers(fromMs: first.startMs, toMs: last.endMs, db: db))
    }) else { return nil }

    var result: [ActivityLedger] = []
    result.reserveCapacity(days.count)
    for day in days {
      guard shouldContinue() else { return nil }
      let isWhole = day.startMs >= fromMs && day.endMs <= toMs
      if isWhole, let ledger = stored[day.startMs] {
        result.append(ledger)
        continue
      }
      guard let sessions = sessionsForDay(day) else { return nil }
      let start = max(day.startMs, fromMs)
      let end = min(day.endMs, toMs)
      let inside = isWhole ? sessions.filter(day.owns) : sessions.filter { $0.endMs >= start && $0.startMs < end }
      guard let texts = try? database.texts(ids: ActivityLedgerBuilder.textIds(for: inside)) else { return nil }
      let ledger = ActivityLedgerBuilder.build(startMs: start, endMs: end, sessions: inside, texts: texts)
      if isWhole, SummaryRangeResolver.isSettled(day, nowMs: now()) {
        _ = try? database.write { try DB.storeActivityLedger(ledger, computedAtMs: now(), expectedInvalidations: expected, db: $0) }
      }
      result.append(ledger)
    }
    return result
  }
}
