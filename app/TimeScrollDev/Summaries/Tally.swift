import Foundation

/// Totals time per name, ignoring case and keeping the first spelling.
struct Tally {
  private var totals: [String: ActivityLedger.Amount] = [:]

  mutating func add(_ name: String, ms: Int64) {
    let key = name.lowercased()
    totals[key] = ActivityLedger.Amount(name: totals[key]?.name ?? name, ms: (totals[key]?.ms ?? 0) + ms)
  }

  func top(_ count: Int) -> [ActivityLedger.Amount] {
    Array(totals.values.sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.name < $1.name }.prefix(count))
  }
}
