import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Keeps app time and stored summaries from outliving, or missing, the captures behind them.
/// Everything here is appended to the statements that change those captures.
extension DB {
  static let summaryInvalidationKey = "summaries.invalidations"

  /// Work that started before a change must not store its result: read this first, then compare it
  /// inside the write.
  static func summaryInvalidationCount(db: OpaquePointer) -> Int64 {
    metaInt(summaryInvalidationKey, db: db) ?? 0
  }

  func summaryInvalidationCount() throws -> Int64 {
    try onReadQueueSync { db in Self.summaryInvalidationCount(db: db) }
  }

  private static var countInvalidationSQL: String {
    "INSERT INTO ts_meta(key, value) VALUES('\(summaryInvalidationKey)', 1) ON CONFLICT(key) DO UPDATE SET value = value + 1;"
  }

  /// A capture changes app time of its own day, and of the previous day if the last capture before
  /// midnight measured its dwell against it (which reaches as far as the idle-gap limit). Ledgers and
  /// summaries reach further: a session belongs to the day it started in, so an earlier period can
  /// hold text from as far past its end as sessions are computed.
  static func summaryInvalidationSQL(captureAt timeMsSQL: String) -> String {
    summaryInvalidationSQL(capturesFromSQL: timeMsSQL, throughSQL: timeMsSQL)
  }

  /// Captures deleted together: every day they could affect, even if a sparse batch skips some.
  static func summaryInvalidationSQL(capturesFromMs fromMs: Int64, throughMs: Int64) -> String {
    summaryInvalidationSQL(capturesFromSQL: "\(fromMs)", throughSQL: "\(throughMs)")
  }

  private static func summaryInvalidationSQL(capturesFromSQL from: String, throughSQL through: String) -> String {
    let margin = SessionDayPlanner.contextMarginMs
    return """
    \(appTimeDayDeletionSQL(where: "day_start_ms <= \(through) AND day_end_ms + \(CaptureDwell.hardBreakMs) > \(from)"))
    DELETE FROM ts_day_ledger WHERE day_start_ms <= \(through) AND day_end_ms + \(margin) > \(from);
    DELETE FROM ts_range_summary WHERE start_ms <= \(through) AND end_ms + \(margin) > \(from);
    \(countInvalidationSQL)
    """
  }

  /// Retention removes everything before the cutoff, which usually falls mid-day.
  static func summaryRetentionSQL(cutoffMs: Int64) -> String {
    """
    \(appTimeDayDeletionSQL(where: "day_start_ms < \(cutoffMs)"))
    DELETE FROM ts_day_ledger WHERE day_start_ms < \(cutoffMs);
    DELETE FROM ts_range_summary WHERE start_ms < \(cutoffMs);
    \(countInvalidationSQL)
    """
  }

  /// All capture text is gone, so summaries must go; app time doesn't depend on text.
  static var allRangeSummariesDeletionSQL: String {
    "DELETE FROM ts_day_ledger; DELETE FROM ts_range_summary; \(countInvalidationSQL)"
  }

  /// For a capture inserted with a past timestamp (queued while the vault was locked).
  func invalidateSummaries(captureAtMs timeMs: Int64) throws {
    try withWriteSavepoint {
      guard let db else { return }
      let result = sqlite3_exec(db, Self.summaryInvalidationSQL(captureAt: "\(timeMs)"), nil, nil, nil)
      guard result == SQLITE_OK else {
        throw NSError(domain: "TS.DB", code: Int(result), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
      }
    }
  }
}
