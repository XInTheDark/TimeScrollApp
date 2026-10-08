import Foundation

/// Immutable description of what the timeline is showing, used to fetch further pages.
struct TimelineQuery: Equatable, Sendable {
    let text: String
    let useAI: Bool
    let fuzziness: SettingsStore.Fuzziness
    let intelligentAccuracy: Bool
    let appBundleIds: [String]?
    let captureKinds: [CaptureKind]?
    let audioSourceKinds: [AudioSourceKind]?
    let startMs: Int64?
    let endMs: Int64?

    /// AI results are ranked by similarity, so time/offset paging does not apply.
    var supportsPaging: Bool { text.isEmpty || !useAI }

    /// Runs the query off the main thread. `startMs`/`endMs` override the stored bounds.
    func fetch(limit: Int, offset: Int, endMs: Int64?, startMs: Int64? = nil) -> [SnapshotMeta] {
        let service = SearchService()
        let start = startMs ?? self.startMs
        if text.isEmpty {
            return service.latestMetas(limit: limit,
                                       offset: offset,
                                       appBundleIds: appBundleIds,
                                       startMs: start,
                                       endMs: endMs,
                                       captureKinds: captureKinds,
                                       audioSourceKinds: audioSourceKinds)
        }
        if useAI {
            return service.searchAIMetas(text,
                                         appBundleIds: appBundleIds,
                                         startMs: start,
                                         endMs: endMs,
                                         captureKinds: captureKinds,
                                         audioSourceKinds: audioSourceKinds,
                                         limit: limit,
                                         offset: offset)
        }
        return service.searchMetas(text,
                                   fuzziness: fuzziness,
                                   intelligentAccuracy: intelligentAccuracy,
                                   appBundleIds: appBundleIds,
                                   startMs: start,
                                   endMs: endMs,
                                   captureKinds: captureKinds,
                                   audioSourceKinds: audioSourceKinds,
                                   limit: limit,
                                   offset: offset)
    }
}
