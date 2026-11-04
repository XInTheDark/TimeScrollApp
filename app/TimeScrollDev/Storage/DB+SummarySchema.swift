import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// Tables behind time range summaries. App time is a rebuildable cache over `ts_snapshot`: a row in
/// `ts_app_time_day` means the day's stats exist, even if it had no activity, and `ts_app_time` is sparse.
extension DB {
  static func createSummaryTablesIfNeeded(db: OpaquePointer) {
    let sql = """
    CREATE TABLE IF NOT EXISTS ts_app_time_day (
        day_start_ms INTEGER PRIMARY KEY,
        day_end_ms INTEGER NOT NULL,
        version INTEGER NOT NULL,
        computed_at_ms INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ts_app_time (
        span INTEGER NOT NULL,
        bucket_ms INTEGER NOT NULL,
        app TEXT NOT NULL,
        dwell_ms INTEGER NOT NULL,
        snapshot_count INTEGER NOT NULL,
        PRIMARY KEY (span, bucket_ms, app)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS ts_range_summary (
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        model TEXT NOT NULL,
        prompt_version INTEGER NOT NULL,
        text TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        PRIMARY KEY (start_ms, end_ms)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS ts_day_ledger (
        day_start_ms INTEGER PRIMARY KEY,
        day_end_ms INTEGER NOT NULL,
        version INTEGER NOT NULL,
        json TEXT NOT NULL,
        computed_at_ms INTEGER NOT NULL
    );
    """
    _ = sqlite3_exec(db, sql, nil, nil, nil)
  }

  /// SQL deleting the matching days and their rows. Matching days must be contiguous.
  static func appTimeDayDeletionSQL(where condition: String) -> String {
    """
    DELETE FROM ts_app_time WHERE span IN (0, 1)
      AND bucket_ms >= (SELECT MIN(day_start_ms) FROM ts_app_time_day WHERE \(condition))
      AND bucket_ms < (SELECT MAX(day_end_ms) FROM ts_app_time_day WHERE \(condition));
    DELETE FROM ts_app_time_day WHERE \(condition);
    """
  }
}
