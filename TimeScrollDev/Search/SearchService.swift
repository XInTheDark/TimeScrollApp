import Foundation

@MainActor
final class SearchService {
    func latestMetas(limit: Int = 1000,
                     appBundleId: String? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil) -> [SnapshotMeta] {
        return (try? DB.shared.latestMetas(limit: limit,
                                           offset: 0,
                                           appBundleId: appBundleId,
                                           startMs: startMs,
                                           endMs: endMs)) ?? []
    }

    func searchMetas(_ query: String,
                     fuzziness: SettingsStore.Fuzziness,
                     appBundleId: String? = nil,
                     startMs: Int64? = nil,
                     endMs: Int64? = nil,
                     limit: Int = 1000) -> [SnapshotMeta] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func prefixLen(for n: Int) -> Int {
            guard n > 2 else { return n }
            switch fuzziness {
            case .off:
                return n
            case .low:
                // Almost exact for low
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
        let fts = perToken.joined(separator: " AND ")
        return (try? DB.shared.searchMetas(fts,
                                           appBundleId: appBundleId,
                                           startMs: startMs,
                                           endMs: endMs,
                                           limit: limit,
                                           offset: 0)) ?? []
    }
}
