import Foundation

/// Resolves a session's keyword hashes back to words, using the texts of its representative screens.
enum SessionLabeler {
  static let maxKeywords = 5

  /// `texts` are the representative screens' texts; words keep their on-screen spelling.
  static func keywords(for hashes: [UInt32], texts: [String]) -> [String] {
    guard !hashes.isEmpty, !texts.isEmpty else { return [] }
    let wanted = Set(hashes)
    var spelling: [UInt32: Substring] = [:]
    for text in texts {
      SessionTextSketch.forEachToken(in: text) { hash, range in
        guard wanted.contains(hash), spelling[hash] == nil else { return }
        spelling[hash] = text[range]
      }
      if spelling.count == wanted.count { break }
    }

    var words: [String] = []
    var seen: Set<String> = []
    for hash in hashes {
      guard let word = spelling[hash].map(String.init) else { continue }
      let folded = word.lowercased()
      guard !stopwords.contains(folded), !looksLikeIdentifierNoise(word), seen.insert(folded).inserted else { continue }
      words.append(word)
      if words.count == maxKeywords { break }
    }
    return words
  }

  /// Hex strings, hashes and similar machine text that is distinctive but meaningless as a label.
  private static func looksLikeIdentifierNoise(_ word: String) -> Bool {
    let scalars = word.unicodeScalars
    guard scalars.count >= 8 else { return false }
    let hex = scalars.filter { hexDigits.contains($0) }.count
    let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
    return hex == scalars.count && digits > 0
  }

  private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

  private static let stopwords: Set<String> = [
    "the", "and", "for", "with", "that", "this", "from", "you", "your", "are", "was", "were", "have", "has",
    "had", "not", "but", "all", "can", "will", "just", "into", "about", "when", "what", "which", "there",
    "their", "they", "them", "then", "than", "also", "more", "some", "such", "only", "other", "over", "our",
    "out", "use", "used", "using", "new", "http", "https", "www", "com", "html", "would", "could", "should",
    "been", "being", "these", "those", "here", "where", "how", "who", "why", "its", "it's", "one", "two",
    "get", "got", "may", "might", "must", "any", "each", "very", "much", "many", "most", "via", "per",
  ]
}
