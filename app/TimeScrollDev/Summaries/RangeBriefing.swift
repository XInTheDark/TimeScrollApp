import Foundation

/// The input for a long range: one section per calendar period, each with an equal share of the budget.
/// What a section doesn't use goes to the ones after it.
enum RangeBriefing {
  struct Section {
    let label: String
    let ledger: ActivityLedger?
    let summaries: [(label: String, text: String)]

    var isEmpty: Bool { (ledger?.isEmpty ?? true) && summaries.isEmpty }
  }

  /// A summary captures meaning, so it gets most of a section when there is one.
  static let summaryShare = 0.65

  static func render(_ sections: [Section], budgetBytes: Int) -> String {
    let active = sections.filter { !$0.isEmpty }
    var remaining = max(0, budgetBytes)
    var blocks: [String] = []
    for (index, section) in active.enumerated() {
      let share = remaining / (active.count - index)
      let block = render(section, toBytes: max(0, share - 2))
      guard !block.isEmpty else { continue }
      blocks.append(block)
      remaining -= block.utf8.count + 2
    }
    return blocks.joined(separator: "\n\n")
  }

  private static func render(_ section: Section, toBytes limit: Int) -> String {
    let heading = "[\(section.label)]"
    var available = limit - heading.utf8.count - 1
    guard available > 0 else { return "" }
    var parts = [heading]

    if !section.summaries.isEmpty {
      let summaryBytes = section.ledger.map { $0.isEmpty ? available : Int(Double(available) * summaryShare) } ?? available
      let each = summaryBytes / section.summaries.count
      for summary in section.summaries {
        let prefix = "Earlier summary, \(summary.label):\n"
        let text = SummaryOutput.trim(summary.text, toBytes: each - prefix.utf8.count - 1)
        guard !text.isEmpty else { continue }
        let block = prefix + text
        parts.append(block)
        available -= block.utf8.count + 1
      }
    }
    if let ledger = section.ledger, available > 10 {
      let prefix = "Measured:\n"
      let text = ActivityLedgerRenderer.render(ledger, toBytes: available - prefix.utf8.count - 1)
      if !text.isEmpty { parts.append(prefix + text) }
    }
    return parts.count > 1 ? parts.joined(separator: "\n") : ""
  }
}
