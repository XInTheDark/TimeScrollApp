import Foundation

/// What plain code can say about a stretch of time, with no model involved: exact app time, the terms
/// that took the most time, and a few lines of screen text. Rebuildable from sessions.
struct ActivityLedger: Codable, Equatable {
  struct Amount: Codable, Equatable {
    let name: String
    let ms: Int64
  }

  struct Line: Codable, Equatable {
    let timeMs: Int64
    let text: String
  }

  /// A stored ledger with another version is rebuilt.
  static let version = 1
  static let maxApps = 6
  static let maxTerms = 24
  static let maxLines = 12
  static let maxLineBytes = 160

  let startMs: Int64
  let endMs: Int64
  let activeMs: Int64
  /// Most time first.
  let apps: [Amount]
  /// Most time first.
  let terms: [Amount]
  /// Most important first.
  let lines: [Line]

  var isEmpty: Bool { activeMs == 0 && apps.isEmpty && terms.isEmpty && lines.isEmpty }
}
