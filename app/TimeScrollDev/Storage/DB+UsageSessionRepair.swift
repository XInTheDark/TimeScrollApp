import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

extension DB {
  /// Trims the usage sessions recorded before sessions stopped spanning system sleep and before
  /// orphans stopped being closed by a later run's first snapshot. Runs once per database.
  ///
  /// Both faults leave the same trace: the session ends right where the next one starts, long
  /// after its own last snapshot. Sessions older than every remaining snapshot can't be judged and
  /// are left alone, unless they reach into the snapshots that do remain.
  static func repairUsageSessionsIfNeeded(db: OpaquePointer) {
    let marker = "usage_session_repair"
    createMetaTableIfNeeded(db: db)
    guard metaInt(marker, db: db) == nil,
          sqlite3_exec(db, "SAVEPOINT usage_session_repair;", nil, nil, nil) == SQLITE_OK else { return }
    var succeeded = sqlite3_exec(db, repairSQL, nil, nil, nil) == SQLITE_OK
    if succeeded {
      do { try setMetaInt(marker, 1, db: db) } catch { succeeded = false }
    }
    if !succeeded { _ = sqlite3_exec(db, "ROLLBACK TO usage_session_repair;", nil, nil, nil) }
    _ = sqlite3_exec(db, "RELEASE usage_session_repair;", nil, nil, nil)
  }

  private static let repairSQL = """
  WITH candidate AS (
    SELECT s.id, s.start_s, s.end_s,
           (SELECT MIN(n.start_s) FROM ts_usage_session n WHERE n.start_s > s.start_s) AS next_s
    FROM ts_usage_session s WHERE s.end_s IS NOT NULL
  ), measured AS (
    SELECT c.id, c.end_s,
           COALESCE((SELECT MAX(started_at_ms) / 1000.0 FROM ts_snapshot
                     WHERE started_at_ms >= c.start_s * 1000
                       AND started_at_ms < MIN(c.end_s, c.next_s) * 1000), c.start_s) AS last_seen_s
    FROM candidate c
    WHERE c.next_s IS NOT NULL AND c.next_s - c.end_s <= 60
      AND c.end_s * 1000 >= (SELECT MIN(started_at_ms) FROM ts_snapshot)
  )
  UPDATE ts_usage_session
  SET end_s = (SELECT last_seen_s FROM measured WHERE measured.id = ts_usage_session.id)
  WHERE id IN (SELECT id FROM measured WHERE end_s - last_seen_s > 1800);
  """
}
