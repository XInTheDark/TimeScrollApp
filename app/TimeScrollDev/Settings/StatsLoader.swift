import Foundation

/// Reads Stats pane numbers off the main thread, on the database's read connection so that a
/// large query never holds up capture writes.
enum StatsLoader {
  static func summary(for window: StatsWindow, now: TimeInterval) -> StatsSummary {
    let cutoffMs = window.cutoffMs(now: now)
    let storage = (try? DB.shared.snapshotStorage(sinceMs: cutoffMs)) ?? .empty
    return StatsSummary(
      snapshotCount: storage.count,
      snapshotBytes: storage.bytes,
      databaseBytes: window.isAllTime ? databaseFileBytes() : nil,
      usageSeconds: usageSeconds(for: window, now: now)
    )
  }

  static func usageSeconds(for window: StatsWindow, now: TimeInterval) -> TimeInterval {
    // Sessions left open by a crash must not count as running until now.
    UsageTracker.shared.closeOrphanedSessions()
    return (try? DB.shared.usageSeconds(from: window.cutoffSeconds(now: now), to: now)) ?? 0
  }

  private static func databaseFileBytes() -> Int64 {
    let dbURL = StoragePaths.dbURL()
    let urls = [dbURL, dbURL.appendingPathExtension("wal"), dbURL.appendingPathExtension("shm")]
      .map { $0.path.replacingOccurrences(of: ".sqlite.", with: ".sqlite-") }
      .map(URL.init(fileURLWithPath:))
    var total: Int64 = 0
    StoragePaths.withSecurityScope {
      for url in urls {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
          total += Int64(values.fileSize ?? 0)
        }
      }
    }
    return total
  }
}
