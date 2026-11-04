import Foundation

/// The shape of a summary. The model must answer with an overview and topics, so a model that ignores
/// layout instructions still produces something readable. It is stored as plain text, which can be
/// copied and fed back into longer summaries: blocks separated by a blank line, where a block of two
/// lines is a title and its text.
enum SummaryOutput {
  struct Section: Equatable {
    let title: String?
    let body: String
  }

  static let maxTopics = 8

  static let jsonSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "overview": ["type": "string"],
      "topics": [
        "type": "array",
        "minItems": 1,
        "maxItems": maxTopics,
        "items": [
          "type": "object",
          "properties": ["title": ["type": "string"], "summary": ["type": "string"]],
          "required": ["title", "summary"],
        ] as [String: Any],
      ] as [String: Any],
    ] as [String: Any],
    "required": ["overview", "topics"],
  ]

  /// Nil when the answer holds no text.
  static func text(fromAnswer answer: [String: Any]) -> String? {
    var blocks: [String] = []
    if let overview = line(answer["overview"]) { blocks.append(overview) }
    let topics = answer["topics"] as? [[String: Any]] ?? []
    for topic in topics.prefix(maxTopics) {
      guard let body = line(topic["summary"]) else { continue }
      blocks.append(line(topic["title"]).map { "\($0)\n\(body)" } ?? body)
    }
    return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
  }

  static func sections(in text: String) -> [Section] {
    text.components(separatedBy: "\n\n").compactMap { block in
      let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      guard let first = lines.first else { return nil }
      guard lines.count > 1 else { return Section(title: nil, body: first) }
      return Section(title: first, body: lines.dropFirst().joined(separator: " "))
    }
  }

  /// Keeps whole blocks from the start, so the overview goes last. Cuts text only when not even the first
  /// block fits.
  static func trim(_ text: String, toBytes limit: Int) -> String {
    guard limit > 0 else { return "" }
    guard text.utf8.count > limit else { return text }
    var kept: [String] = []
    var used = 0
    for block in text.components(separatedBy: "\n\n") {
      let size = block.utf8.count + (kept.isEmpty ? 0 : 2)
      if used + size > limit { break }
      kept.append(block)
      used += size
    }
    return kept.isEmpty ? RepresentativeTextSelector.truncate(text, toBytes: limit) : kept.joined(separator: "\n\n")
  }

  private static func line(_ value: Any?) -> String? {
    let words = (value as? String)?.split(whereSeparator: \.isWhitespace) ?? []
    return words.isEmpty ? nil : words.joined(separator: " ")
  }
}
