import Foundation

/// Utility to generate small sets of likely OCR-confusion variants for a token.
/// Keeps expansion conservative to avoid MATCH query blowup.
enum OCRConfusion {
    /// Bidirectional substitution rules. All tokens are treated as lowercased.
    /// Multi-graph rules included (e.g., rn↔m, vv↔w, cl↔d).
    private static let rules: [(from: String, tos: [String])] = [
        ("i", ["l", "1"]),
        ("l", ["i", "1"]),
        ("1", ["i", "l"]),
        ("o", ["0"]),
        ("0", ["o"]),
        ("m", ["rn"]),
        ("rn", ["m"]),
        ("w", ["vv"]),
        ("vv", ["w"]),
        ("d", ["cl"]),
        ("cl", ["d"]),
    ]

    /// Expand a token into a small set of confusion variants.
    /// - Parameters:
    ///   - token: input token (any case); normalized to lowercase internally.
    ///   - maxVariants: global cap including the original token.
    ///   - maxSubs: maximum number of substitutions applied cumulatively.
    ///   - maxLen: skip expansion when token is longer than this.
    static func expand(_ token: String,
                        maxVariants: Int = 32,
                       maxSubs: Int = 2,
                       maxLen: Int = 20) -> [String] {
        let base = token.lowercased()
        if base.isEmpty { return [] }
        if base.count > maxLen { return [base] }

        // BFS over substitutions with tight caps
        var results: Set<String> = [base]
        struct Node { let s: String; let subs: Int }
        var queue: [Node] = [Node(s: base, subs: 0)]

        func applyRules(to s: String) -> [String] {
            var out: [String] = []
            for (from, tos) in rules {
                var searchRange = s.startIndex..<s.endIndex
                while let r = s.range(of: from, options: [.literal], range: searchRange) {
                    for t in tos {
                        var ns = s
                        ns.replaceSubrange(r, with: t)
                        out.append(ns)
                    }
                    // Continue search after this replacement site
                    searchRange = r.upperBound..<s.endIndex
                }
            }
            return out
        }

        while !queue.isEmpty && results.count < maxVariants {
            let node = queue.removeFirst()
            if node.subs >= maxSubs { continue }
            for cand in applyRules(to: node.s) {
                if results.insert(cand).inserted {
                    queue.append(Node(s: cand, subs: node.subs + 1))
                    if results.count >= maxVariants { break }
                }
            }
        }
        // Return deterministic order: base first, others sorted for stability
        let others = results.subtracting([base]).sorted()
        return [base] + others
    }
}

