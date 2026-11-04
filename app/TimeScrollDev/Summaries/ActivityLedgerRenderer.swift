import Foundation

/// A ledger as text for the model, never over the byte limit.
enum ActivityLedgerRenderer {
  static func render(_ ledger: ActivityLedger, toBytes limit: Int) -> String {
    guard limit > 0, !ledger.isEmpty else { return "" }
    var parts: [String] = []
    var remaining = limit
    func add(_ text: String) {
      let size = text.utf8.count + (parts.isEmpty ? 0 : 1)
      guard size <= remaining else { return }
      parts.append(text)
      remaining -= size
    }
    if let line = list("Apps: ", ledger.apps.map(\.name), toBytes: min(limit / 5, remaining)) { add(line) }
    if let line = list("Terms: ", ledger.terms.map(\.name), toBytes: min(limit / 3, remaining)) { add(line) }
    for line in ledger.lines { add("- " + line.text) }
    return parts.joined(separator: "\n")
  }

  /// As many whole names as fit.
  private static func list(_ title: String, _ names: [String], toBytes limit: Int) -> String? {
    var text = title
    var count = 0
    for name in names {
      let separator = count == 0 ? "" : ", "
      if text.utf8.count + separator.utf8.count + name.utf8.count > limit { break }
      text += separator + name
      count += 1
    }
    return count == 0 ? nil : text
  }
}
