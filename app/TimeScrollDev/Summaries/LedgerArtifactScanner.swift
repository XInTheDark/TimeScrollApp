import Foundation

/// Finds file names and ticket ids in screen text, which keyword statistics tend to miss.
enum LedgerArtifactScanner {
  static let maxPerText = 8
  private static let pattern = try? NSRegularExpression(
    pattern: #"\b[\w-]{2,64}\.(?:swift|py|ts|tsx|js|jsx|go|rs|rb|java|kt|c|h|cpp|m|json|ya?ml|toml|sql|sh|md|txt|csv|pdf|docx?|xlsx?|pptx?|key|numbers|pages)\b|\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b"#)

  static func artifacts(in text: String) -> [String] {
    guard let pattern else { return [] }
    var seen = Set<String>()
    var found: [String] = []
    let whole = NSRange(text.startIndex..., in: text)
    pattern.enumerateMatches(in: text, range: whole) { match, _, stop in
      guard let match, let range = Range(match.range, in: text) else { return }
      let artifact = String(text[range])
      if seen.insert(artifact.lowercased()).inserted { found.append(artifact) }
      if found.count >= maxPerText { stop.pointee = true }
    }
    return found
  }
}
