import Foundation

// Types SnapshotMeta and SearchResult are part of the main target; no extra imports required.

@MainActor
final class SearchService {
    // Build per-part FTS query fragments from a user query. Each returned string is intended
    // to be bound to an individual "t.content MATCH ?" and AND-combined at the SQL level.
    func ftsParts(for query: String,
                  fuzziness: SettingsStore.Fuzziness,
                  intelligentAccuracy: Bool) -> [String] {
        let parsed = SearchQueryParser.parse(query)
        guard !parsed.parts.isEmpty else { return [] }
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
        var parts: [String] = []
        for part in parsed.parts {
            if part.isPhrase {
                // exact phrase: wrap in quotes, no fuzziness or expansion
                let escaped = part.text.lowercased().replacingOccurrences(of: "\"", with: " ")
                parts.append("\"\(escaped)\"")
                continue
            }
            let token = part.text.lowercased()
            if token.isEmpty { continue }

            // Expand with OCR confusion variants if enabled
            let variants: [String]
            if intelligentAccuracy {
                variants = OCRConfusion.expand(token)
            } else {
                variants = [token]
            }

            // Apply fuzziness (prefix) per-variant when applicable
            let n = token.count
            let usePrefix = !(n <= 2 || fuzziness == .off || (fuzziness == .low && n <= 5))
            if usePrefix {
                let p = prefixLen(for: n)
                let expanded = variants.map { v in
                    let pref = String(v.prefix(min(p, v.count)))
                    return "\(pref)*"
                }
                // Join OR without parentheses; SQL layer will AND multiple MATCH clauses
                parts.append(expanded.joined(separator: " OR "))
            } else {
                parts.append(variants.joined(separator: " OR "))
            }
        }
        return parts
    }

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

    // Build a legacy single-string preview honoring fuzziness & phrase rules.
    // Note: the actual DB layer uses per-part MATCH bindings; this joined string is for tests/logging.
    func ftsQuery(for query: String, fuzziness: SettingsStore.Fuzziness) -> String {
        let ia = SettingsStore.shared.intelligentAccuracy
        let parts = ftsParts(for: query, fuzziness: fuzziness, intelligentAccuracy: ia)
        return parts.joined(separator: " AND ")
    }

    func searchMetas(_ query: String,
                     fuzziness: SettingsStore.Fuzziness,
                     appBundleIds: [String]? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000,
                     offset: Int = 0) -> [SnapshotMeta] {
        let ia = SettingsStore.shared.intelligentAccuracy
        let parts = ftsParts(for: query, fuzziness: fuzziness, intelligentAccuracy: ia)
        return (try? DB.shared.searchMetas(parts,
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
        let ia = SettingsStore.shared.intelligentAccuracy
        let parts = ftsParts(for: query, fuzziness: fuzziness, intelligentAccuracy: ia)
        return (try? DB.shared.searchWithContent(parts,
                                                 appBundleIds: appBundleIds,
                                                 startMs: startMs,
                                                 endMs: endMs,
                                                 limit: limit,
                                                 offset: offset)) ?? []
    }
}
