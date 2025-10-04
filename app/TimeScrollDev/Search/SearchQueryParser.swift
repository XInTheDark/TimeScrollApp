import Foundation

/// Parsed representation of a user search query.
public struct ParsedSearchQuery {
    public struct Part: Equatable {
        public let text: String      // sanitized text (for phrases it preserves inner spaces)
        public let isPhrase: Bool    // true if originally quoted with "..."
    }
    public let parts: [Part]
}

/// Lightweight parser that understands:
/// - quoted phrases: "hello world" kept verbatim and matched exactly (no fuzziness applied)
/// - normal tokens: split by whitespace
/// - sanitization: keep only alphanumerics and spaces inside phrases (to avoid FTS errors)
struct SearchQueryParser {
    static func parse(_ raw: String) -> ParsedSearchQuery {
        var i = raw.startIndex
        var parts: [ParsedSearchQuery.Part] = []
        func sanitizeToken(_ s: Substring) -> String {
            let scalars = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            return String(String.UnicodeScalarView(scalars))
        }
        while i < raw.endIndex {
            // Skip whitespace
            if raw[i].isWhitespace { i = raw.index(after: i); continue }
            let c = raw[i]
            if c == "\"" { // phrase
                var j = raw.index(after: i)
                var phraseEnded = false
                while j < raw.endIndex {
                    if raw[j] == "\"" { phraseEnded = true; break }
                    j = raw.index(after: j)
                }
                let inner = raw.index(after: i)..<j
                let sanitized = sanitizePhrase(raw[inner])
                if !sanitized.isEmpty { parts.append(.init(text: sanitized, isPhrase: true)) }
                i = phraseEnded ? raw.index(after: j) : j
            } else { // token
                var j = i
                while j < raw.endIndex && !raw[j].isWhitespace { j = raw.index(after: j) }
                let tokenSub = raw[i..<j]
                let tokenStr = String(tokenSub)
                let sanitized = sanitizeToken(Substring(tokenStr))
                if !sanitized.isEmpty { parts.append(.init(text: sanitized, isPhrase: false)) }
                i = j
            }
        }
        return ParsedSearchQuery(parts: parts)
    }

    private static func sanitizePhrase(_ s: Substring) -> String {
        // Allow spaces but strip punctuation to keep FTS happy
        let scalars = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        // Collapse consecutive spaces
        let collapsed = String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
