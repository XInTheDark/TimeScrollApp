import Foundation

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

    // AI mode: use sentence embeddings to score results by cosine similarity.
    // Implementation notes:
    // - Fetches up to maxCandidates items with embeddings from DB (time/app filters applied)
    // - Computes dot-product (cosine, since vectors are L2-normalized) and filters by threshold
    // - Sorts by similarity then recency; returns a page (limit/offset) just like FTS
    func searchAI(_ query: String,
                  appBundleIds: [String]?,
                  startMs: Int64?,
                  endMs: Int64?,
                  limit: Int,
                  offset: Int) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Fallback to latest when no query present
            return latestWithContent(limit: limit, offset: offset, appBundleIds: appBundleIds, startMs: startMs, endMs: endMs)
        }
        let svc = EmbeddingService.shared
        let (qVec, known, total) = svc.embedWithStats(trimmed)
        let maxC = svc.maxCandidates
        let thresh = Float(svc.threshold)
        // Fetch candidate rows (filtered by both dimension AND provider)
        let candidates = (try? DB.shared.embeddingCandidates(appBundleIds: appBundleIds,
                                                             startMs: startMs,
                                                             endMs: endMs,
                                                             limit: maxC,
                                                             offset: 0,
                                                             requireDim: svc.dim,
                                                             requireProvider: svc.providerID)) ?? []
        if UserDefaults.standard.bool(forKey: "settings.debugMode") {
            let head = qVec.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
            print("[AI][Query] dim=\(qVec.count) tokens=\(known)/\(total) threshold=\(String(format: "%.2f", thresh)) candidates=\(candidates.count) head=[\(head)]")
        }
        // Score
        var scored: [(SearchResult, Float)] = []
        scored.reserveCapacity(candidates.count)
        for c in candidates {
            let s = EmbeddingService.dot(qVec, c.vector)
            if s >= thresh { scored.append((c.result, s)) }
        }
        if UserDefaults.standard.bool(forKey: "settings.debugMode") {
            let scores = scored.map { $0.1 }.sorted(by: >)
            let top = scores.prefix(5).map { String(format: "%.3f", $0) }.joined(separator: ", ")
            print("[AI][Score] kept=\(scored.count) / \(candidates.count) top5=[\(top)]")
        }
        // Sort by score desc then recency desc
        scored.sort { (a, b) in
            if a.1 == b.1 { return a.0.startedAtMs > b.0.startedAtMs }
            return a.1 > b.1
        }
        // Page
        let start = max(0, offset)
        let end = min(scored.count, start + limit)
        guard start < end else { return [] }
        return scored[start..<end].map { $0.0 }
    }

    // AI search returning metas for timeline display (no content)
    func searchAIMetas(_ query: String,
                       appBundleIds: [String]?,
                       startMs: Int64?,
                       endMs: Int64?,
                       limit: Int,
                       offset: Int = 0) -> [SnapshotMeta] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Fallback to latest when no query present
            return latestMetas(limit: limit, offset: offset, appBundleIds: appBundleIds, startMs: startMs, endMs: endMs)
        }
        let svc = EmbeddingService.shared
        let (qVec, _, _) = svc.embedWithStats(trimmed)
        let maxC = svc.maxCandidates
        let thresh = Float(svc.threshold)
        // Fetch candidate rows (filtered by both dimension AND provider)
        let candidates = (try? DB.shared.embeddingCandidates(appBundleIds: appBundleIds,
                                                             startMs: startMs,
                                                             endMs: endMs,
                                                             limit: maxC,
                                                             offset: 0,
                                                             requireDim: svc.dim,
                                                             requireProvider: svc.providerID)) ?? []
        // Score and filter
        var scored: [(SnapshotMeta, Float)] = []
        scored.reserveCapacity(candidates.count)
        for c in candidates {
            let s = EmbeddingService.dot(qVec, c.vector)
            if s >= thresh {
                let meta = SnapshotMeta(id: c.result.id,
                                        startedAtMs: c.result.startedAtMs,
                                        path: c.result.path,
                                        appBundleId: c.result.appBundleId,
                                        appName: c.result.appName,
                                        thumbPath: nil)
                scored.append((meta, s))
            }
        }
        // Sort by score desc then recency desc
        scored.sort { (a, b) in
            if a.1 == b.1 { return a.0.startedAtMs > b.0.startedAtMs }
            return a.1 > b.1
        }
        // Page
        let start = max(0, offset)
        let end = min(scored.count, start + limit)
        guard start < end else { return [] }
        return scored[start..<end].map { $0.0 }
    }
}
