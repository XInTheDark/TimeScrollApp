import Foundation

/// Stats for one resolved range: exact totals, and the largest apps with the rest as "other".
struct AppTimeReport: Equatable {
  struct Entry: Equatable {
    let app: String
    var name: String?
    let dwellMs: Int64
    let snapshotCount: Int64
  }

  let range: ResolvedSummaryRange
  let totalDwellMs: Int64
  let snapshotCount: Int64
  var topApps: [Entry]
  let otherDwellMs: Int64
  let distinctApps: Int
  /// True when some bucket hit the app limit, so `distinctApps` may be too low.
  let distinctAppsIsLowerBound: Bool

  init(range: ResolvedSummaryRange, rows: [AppTimeRow], topK: Int) {
    var totals: [String: (dwellMs: Int64, count: Int64)] = [:]
    var total: Int64 = 0
    var snapshots: Int64 = 0
    for row in rows {
      let entry = totals[row.app] ?? (0, 0)
      totals[row.app] = (entry.dwellMs + row.dwellMs, entry.count + row.snapshotCount)
      total += row.dwellMs
      snapshots += row.snapshotCount
    }
    let folded = totals.removeValue(forKey: AppTimeRow.otherApp)
    let sorted = totals.sorted { $0.value.dwellMs != $1.value.dwellMs ? $0.value.dwellMs > $1.value.dwellMs : $0.key < $1.key }
    let limit = max(0, topK)

    self.range = range
    totalDwellMs = total
    snapshotCount = snapshots
    topApps = sorted.prefix(limit).map { Entry(app: $0.key, name: nil, dwellMs: $0.value.dwellMs, snapshotCount: $0.value.count) }
    otherDwellMs = sorted.dropFirst(limit).reduce(folded?.dwellMs ?? 0) { $0 + $1.value.dwellMs }
    distinctApps = totals.keys.filter { $0 != AppTimeRow.unknownApp }.count
    distinctAppsIsLowerBound = folded != nil
  }
}
