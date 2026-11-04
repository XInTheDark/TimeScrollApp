import Foundation

/// Fits a range's sessions into a fixed text budget, whatever the range's length. Sessions with the
/// most time win, and each gets a share of the budget in proportion to its time. Budgets are UTF-8
/// bytes, which track model tokens more evenly across languages than characters do.
enum RepresentativeTextSelector {
  static let headerBytes = 160
  static let minimumExcerptBytes = 80

  struct Allocation: Equatable {
    let session: ActivitySession
    let excerptBytes: Int
  }

  /// Chosen sessions in time order. `app` keeps only sessions that name that app.
  static func allocate(sessions: [ActivitySession], budgetBytes: Int, app: String? = nil) -> [Allocation] {
    let candidates = app.map { wanted in sessions.filter { $0.apps.contains { $0.bundleId == wanted || $0.name == wanted } } } ?? sessions
    let capacity = max(0, budgetBytes) / (headerBytes + minimumExcerptBytes)
    let chosen = candidates
      .sorted { weight($0) != weight($1) ? weight($0) > weight($1) : $0.id < $1.id }
      .prefix(capacity)
    guard !chosen.isEmpty else { return [] }
    let excerptBudget = budgetBytes - chosen.count * headerBytes
    let totalWeight = chosen.reduce(Int64(0)) { $0 + weight($1) }
    return chosen
      .map { Allocation(session: $0, excerptBytes: Int(Int64(excerptBudget) * weight($0) / totalWeight)) }
      .sorted { $0.session.startMs != $1.session.startMs ? $0.session.startMs < $1.session.startMs : $0.session.id < $1.session.id }
  }

  /// One block per session. Missing texts are skipped, so the result can come in under budget.
  static func render(_ allocations: [Allocation], texts: [Int64: String], timeLabel: (Int64) -> String) -> String {
    allocations.map { allocation in
      let session = allocation.session
      var header = "- \(timeLabel(session.startMs)), \(session.title)"
      if !session.keywords.isEmpty { header += ": \(session.keywords.joined(separator: ", "))" }
      var block = truncate(header, toBytes: headerBytes - 1) + "\n"

      let available = session.representativeTextIds.compactMap { texts[$0] }
      if !available.isEmpty {
        let excerpt = ExcerptLineSelector.select(texts: available, keywords: session.keywords, toBytes: allocation.excerptBytes - 1)
        if !excerpt.isEmpty { block += excerpt + "\n" }
      }
      return block
    }.joined()
  }

  /// Cuts on a character boundary, never exceeding `limit` bytes.
  static func truncate(_ text: String, toBytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var used = 0
    var end = text.startIndex
    for index in text.indices {
      let size = String(text[index]).utf8.count
      if used + size > limit { break }
      used += size
      end = text.index(after: index)
    }
    return String(text[..<end])
  }

  private static func weight(_ session: ActivitySession) -> Int64 {
    max(1, session.durationMs, session.apps.reduce(0) { $0 + $1.ms })
  }
}
