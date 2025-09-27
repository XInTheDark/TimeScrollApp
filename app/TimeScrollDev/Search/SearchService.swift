import Foundation

@MainActor
final class SearchService {
    func latestMetas(limit: Int = 1000,
                     offset: Int = 0,
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil) -> [SnapshotMeta] {
        return (try? DB.shared.latestMetas(limit: limit,
                                           offset: offset,
                                           appBundleIds: appBundleIds,
                                           startMs: startMs,
                                           endMs: endMs)) ?? []
    }

    // Build an FTS query string honoring fuzziness rules
    func ftsQuery(for query: String, fuzziness: SettingsStore.Fuzziness) -> String {
        let rawTokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Sanitize tokens to avoid FTS syntax errors from punctuation
        func sanitize(_ s: String) -> String {
            let scalars = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            return String(String.UnicodeScalarView(scalars))
        }
        let tokens = rawTokens.map { sanitize($0) }.filter { !$0.isEmpty }
        func prefixLen(for n: Int) -> Int {
            guard n > 2 else { return n }
            switch fuzziness {
            case .off:
                return n
            case .low:
                return n <= 5 ? n : max(3, n - 1)
            case .medium:
                let calc = Int(ceil(Double(n) * 0.70))
                return max(3, min(n, calc))
            case .high:
                let calc = Int(ceil(Double(n) * 0.60))
                return max(3, min(n, calc))
            }
        }
        let perToken = tokens.map { tok -> String in
            let n = tok.count
            if fuzziness == .off || n <= 2 { return tok }
            if fuzziness == .low && n <= 5 { return tok }
            let p = String(tok.prefix(prefixLen(for: n)))
            return "\(p)*"
        }
        return perToken.joined(separator: " AND ")
    }

    func searchMetas(_ query: String,
                     fuzziness: SettingsStore.Fuzziness,
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) -> [SnapshotMeta] {
        let fts = ftsQuery(for: query, fuzziness: fuzziness)
        return (try? DB.shared.searchMetas(fts,
                                           appBundleIds: appBundleIds,
                                           startMs: startMs,
                                           endMs: endMs,
                                           limit: limit,
                                           offset: offset)) ?? []
    }

    // Paged results including raw content for snippet building
    func latestWithContent(limit: Int,
                           offset: Int,
                           appBundleIds: [String]?,
                           startMs: Int64?,
                           endMs: Int64?) -> [SearchResult] {
        return (try? DB.shared.latestWithContent(limit: limit,
                                                 offset: offset,
                                                 appBundleIds: appBundleIds,
                                                 startMs: startMs,
                                                 endMs: endMs)) ?? []
    }

    func searchWithContent(_ query: String,
                           fuzziness: SettingsStore.Fuzziness,
                           appBundleIds: [String]?,
                           startMs: Int64?,
                           endMs: Int64?,
                           limit: Int,
                           offset: Int) -> [SearchResult] {
        let fts = ftsQuery(for: query, fuzziness: fuzziness)
        return (try? DB.shared.searchWithContent(fts,
                                                 appBundleIds: appBundleIds,
                                                 startMs: startMs,
                                                 endMs: endMs,
                                                 limit: limit,
                                                 offset: offset)) ?? []
    }
}
