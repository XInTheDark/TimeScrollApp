import Foundation

/// Adds ledgers together for a longer period. Exact apart from what each ledger already left out.
enum ActivityLedgerMerger {
  static let maxMergedTerms = ActivityLedger.maxTerms * 2
  static let maxMergedLines = ActivityLedger.maxLines * 4

  static func merge(_ ledgers: [ActivityLedger], startMs: Int64, endMs: Int64) -> ActivityLedger {
    var apps = Tally()
    var terms = Tally()
    var activeMs: Int64 = 0
    for ledger in ledgers {
      activeMs += ledger.activeMs
      for app in ledger.apps { apps.add(app.name, ms: app.ms) }
      for term in ledger.terms { terms.add(term.name, ms: term.ms) }
    }
    return ActivityLedger(startMs: startMs, endMs: endMs, activeMs: activeMs,
                          apps: apps.top(ActivityLedger.maxApps), terms: terms.top(maxMergedTerms),
                          lines: spread(ledgers))
  }

  /// Takes lines evenly from each ledger, so one busy day can't crowd out the others.
  private static func spread(_ ledgers: [ActivityLedger]) -> [ActivityLedger.Line] {
    var lines: [ActivityLedger.Line] = []
    var depth = 0
    while lines.count < maxMergedLines {
      let round = ledgers.filter { depth < $0.lines.count }
      guard !round.isEmpty else { break }
      for ledger in round where lines.count < maxMergedLines { lines.append(ledger.lines[depth]) }
      depth += 1
    }
    return lines
  }
}
