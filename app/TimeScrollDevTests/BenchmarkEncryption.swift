import Foundation
import SQLCipher

/// With `TEST_RUNNER_TIMESCROLL_BENCHMARK_CIPHER=1`, benchmark databases use the vault's storage
/// settings: SQLCipher with a raw key, WAL and normal sync. Must run before any other statement.
enum BenchmarkEncryption {
  static func applyIfRequested(to db: OpaquePointer) {
    guard ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARK_CIPHER"] == "1" else { return }
    let key = String(repeating: "ab", count: 32)
    let sql = "PRAGMA key = \"x'\(key)'\"; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;"
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    precondition(result == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
  }

  /// Moves seeded rows out of the WAL, so the first measurement doesn't pay to checkpoint them.
  static func checkpointIfRequested(_ db: OpaquePointer) {
    guard ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARK_CIPHER"] == "1" else { return }
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
  }
}
