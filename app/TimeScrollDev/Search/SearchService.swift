import Foundation
// Types SnapshotMeta and SearchResult are part of the main target; no extra imports required.

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

    // Build an FTS query string honoring fuzziness rules and quoted phrases (exact phrases).
    func ftsQuery(for query: String, fuzziness: SettingsStore.Fuzziness) -> String {
        let parsed = SearchQueryParser.parse(query)
        guard !parsed.parts.isEmpty else { return "" }
        func prefixLen(for n: Int) -> Int {
            guard n > 2 else { return n }
            switch fuzziness {
            case .off: return n
            case .low: return n <= 5 ? n : max(3, n - 1)
            case .medium:
                return max(3, min(n, Int(ceil(Double(n) * 0.70))))
            case .high:
                return max(3, min(n, Int(ceil(Double(n) * 0.60))))
            }
        }
        var out: [String] = []
        for part in parsed.parts {
            if part.isPhrase { // exact phrase: wrap in quotes, no fuzziness
                let escaped = part.text.lowercased().replacingOccurrences(of: "\"", with: " ")
                out.append("\"\(escaped)\"")
                continue
            }
            let token = part.text.lowercased()
            if token.isEmpty { continue }
            let n = token.count
            // Apply fuzziness to tokens of length >= 3 only; always include short tokens verbatim
            if n <= 2 || fuzziness == .off || (fuzziness == .low && n <= 5) {
                out.append(token)
            } else {
                let p = String(token.prefix(prefixLen(for: n)))
                out.append("\(p)*")
            }
        }
        return out.joined(separator: " AND ")
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
