import Foundation

/// Chooses the lines of a session's screens worth showing the model. Lines repeated across screens are
/// probably menus and toolbars, and lines with the session's keywords are probably its content.
enum ExcerptLineSelector {
  static let maxChunkBytes = 200
  static let maxLinesPerScreen = 400
  private static let minimumUsefulBytes = 8
  private static let substantialBytes = 20

  private struct Candidate {
    let text: String
    let order: Int
    let score: Int
  }

  /// Best first, without duplicates.
  static func ranked(texts: [String], keywords: [String]) -> [String] {
    candidates(texts: texts, keywords: keywords).map(\.text)
  }

  /// In reading order, one per line, never over `limit` bytes.
  static func select(texts: [String], keywords: [String], toBytes limit: Int) -> String {
    guard limit > 0 else { return "" }
    let all = candidates(texts: texts, keywords: keywords)
    var used = 0
    var chosen: [Candidate] = []
    for candidate in all {
      let size = candidate.text.utf8.count + (chosen.isEmpty ? 0 : 1)
      if used + size > limit { continue }
      used += size
      chosen.append(candidate)
    }
    if chosen.isEmpty, let best = all.first {
      return RepresentativeTextSelector.truncate(best.text, toBytes: limit)
    }
    return chosen.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n")
  }

  private static func candidates(texts: [String], keywords: [String]) -> [Candidate] {
    let screens = texts.map(lines)
    var screensWithLine: [String: Int] = [:]
    for screen in screens {
      for line in Set(screen.map { $0.lowercased() }) { screensWithLine[line, default: 0] += 1 }
    }
    let folded = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
    let distinctScreens = Set(texts).count
    var seen = Set<String>()
    var result: [Candidate] = []
    var order = 0
    for screen in screens {
      for line in screen {
        let key = line.lowercased()
        guard seen.insert(key).inserted else { continue }
        var score = folded.reduce(0) { $0 + (key.contains($1) ? 4 : 0) }
        if distinctScreens > 1, screensWithLine[key, default: 0] > 1 { score -= 2 }
        let bytes = line.utf8.count
        if bytes >= substantialBytes { score += 1 }
        if bytes < minimumUsefulBytes { score -= 3 }
        result.append(Candidate(text: line, order: order, score: score))
        order += 1
      }
    }
    return result.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
  }

  /// A screen's lines with whitespace collapsed, and long lines split so each can be chosen alone.
  private static func lines(in text: String) -> [String] {
    var result: [String] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard !line.isEmpty else { continue }
      var rest = Substring(line)
      while !rest.isEmpty, result.count < maxLinesPerScreen {
        let chunk = RepresentativeTextSelector.truncate(String(rest), toBytes: maxChunkBytes)
        guard !chunk.isEmpty else { break }
        result.append(chunk.trimmingCharacters(in: .whitespaces))
        rest = rest.dropFirst(chunk.count)
      }
      if result.count >= maxLinesPerScreen { break }
    }
    return result.filter { !$0.isEmpty }
  }
}
