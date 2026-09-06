import Foundation
import SwiftUI
import AppKit

@MainActor
final class TimelineModel: ObservableObject {
    // Filters
    @Published var query: String = ""
    @Published var selectedAppBundleIds: Set<String> = []
    @Published var selectedCaptureKinds: Set<CaptureKind> = []
    @Published var selectedAudioSourceKinds: Set<AudioSourceKind> = []
    @Published var startMs: Int64? = nil
    @Published var endMs: Int64? = nil

    // Data
    @Published private(set) var metas: [SnapshotMeta] = [] { // DESC by time
        didSet { dataRevision &+= 1 }
    }
    private(set) var dataRevision: UInt64 = 0
    @Published private(set) var segments: [TimelineSegment] = [] // chronological
    @Published var selectedIndex: Int = -1
    @Published var jumpToEndToken: Int = 0

    // Zoom + UI state
    @AppStorage("ui.timeline.msPerPoint") var msPerPoint: Double = 60_000
    @AppStorage("ui.actionPanelExpanded") var actionPanelExpanded: Bool = false
    @AppStorage("ui.timeline.followLatest") var followLatest: Bool = false
    @AppStorage("ui.overlay.offsetX") var overlayOffsetX: Double = 0
    @AppStorage("ui.overlay.offsetY") var overlayOffsetY: Double = 220

    // Hover state (for preview)
    @Published var hoverTimeMs: Int64? = nil
    @Published var playbackTimeMs: Int64? = nil
    @Published var isLoading: Bool = false

    private var timesAsc: [Int64] = []
    private var requestToken: Int = 0

    var minTimeMs: Int64 { metas.last?.startedAtMs ?? 0 }
    var maxTimeMs: Int64 { metas.first?.startedAtMs ?? 0 }
    var selected: SnapshotMeta? { metas.indices.contains(selectedIndex) ? metas[selectedIndex] : nil }

    init() {
        overlayOffsetX = 0
        overlayOffsetY = 220
    }

    func load(limit: Int = 1000) {
        requestToken &+= 1
        let token = requestToken
        isLoading = true
        Task { @MainActor in await Task.yield() }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSelectedId = selected?.id
        let settings = SettingsStore.shared
        let useAI = settings.aiEmbeddingsEnabled && settings.aiModeOn && EmbeddingService.shared.dim > 0
        let ia = settings.intelligentAccuracy
        let fuzz = settings.fuzziness
        let appIds = selectedAppBundleIds.isEmpty ? nil : Array(selectedAppBundleIds)
        let captureKinds = selectedCaptureKinds.isEmpty ? nil : Array(selectedCaptureKinds)
        let audioSourceKinds = selectedAudioSourceKinds.isEmpty ? nil : Array(selectedAudioSourceKinds)
        let start = startMs
        let end = endMs

        DispatchQueue.global(qos: .userInitiated).async { [limit, trimmed, appIds, captureKinds, audioSourceKinds, start, end, useAI, fuzz, ia] in
            let searchSvc = SearchService()
            let list: [SnapshotMeta]
            if trimmed.isEmpty {
                list = searchSvc.latestMetas(
                    limit: limit,
                    appBundleIds: appIds,
                    startMs: start,
                    endMs: end,
                    captureKinds: captureKinds,
                    audioSourceKinds: audioSourceKinds
                )
            } else if useAI {
                list = searchSvc.searchAIMetas(
                    trimmed,
                    appBundleIds: appIds,
                    startMs: start,
                    endMs: end,
                    captureKinds: captureKinds,
                    audioSourceKinds: audioSourceKinds,
                    limit: limit
                )
            } else {
                list = searchSvc.searchMetas(
                    trimmed,
                    fuzziness: fuzz,
                    intelligentAccuracy: ia,
                    appBundleIds: appIds,
                    startMs: start,
                    endMs: end,
                    captureKinds: captureKinds,
                    audioSourceKinds: audioSourceKinds,
                    limit: limit
                )
            }

            let sorted = list.sorted { $0.startedAtMs > $1.startedAtMs }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard token == self.requestToken else { return }
                self.metas = sorted
                if self.followLatest {
                    self.selectedIndex = self.metas.isEmpty ? -1 : 0
                } else if let prev = previousSelectedId,
                          let idx = self.metas.firstIndex(where: { $0.id == prev }) {
                    self.selectedIndex = idx
                } else {
                    self.selectedIndex = self.metas.isEmpty ? -1 : 0
                }
                self.rebuildAscCache()
                self.refreshSegments()
                if !self.msPerPoint.isFinite || self.msPerPoint <= 0 {
                    self.msPerPoint = self.defaultMsPerPoint()
                }
                self.isLoading = false
            }
        }
    }

    func refreshSegments() {
        segments.removeAll()
        guard !metas.isEmpty else { return }

        let asc = metas.sorted { $0.startedAtMs < $1.startedAtMs }
        let inactivityBreakMs: Int64 = 60_000

        var current = asc[0]
        var segmentKey = TimelineSegmentKey(meta: current)
        var segStart = current.startedAtMs
        var lastEnd = resolvedEndMs(for: current)
        var nonAppAccum: Int64 = 0

        func appendCurrentSegment() {
            segments.append(
                TimelineSegment(
                    appBundleId: current.appBundleId,
                    appName: current.appName,
                    captureKind: current.captureKind,
                    audioSourceKind: current.audioSourceKind,
                    startMs: segStart,
                    endMs: max(lastEnd, segStart),
                    toleratedNonAppMs: Int64((0.10 * Double(max(0, lastEnd - segStart))).rounded(.up)),
                    actualNonAppMs: nonAppAccum
                )
            )
        }

        guard asc.count > 1 else {
            appendCurrentSegment()
            return
        }

        for index in 1..<asc.count {
            let item = asc[index]
            let itemKey = TimelineSegmentKey(meta: item)
            let previous = asc[index - 1]
            let dt = max(0, item.startedAtMs - previous.startedAtMs)

            if dt > inactivityBreakMs {
                appendCurrentSegment()
                current = item
                segmentKey = itemKey
                segStart = item.startedAtMs
                lastEnd = resolvedEndMs(for: item)
                nonAppAccum = 0
                continue
            }

            if itemKey == segmentKey {
                current = item
                lastEnd = max(lastEnd, resolvedEndMs(for: item))
                continue
            }

            let provisional = max(1, item.startedAtMs - segStart)
            let allowed = Int64((0.10 * Double(provisional)).rounded(.up))
            if nonAppAccum + dt <= allowed {
                nonAppAccum += dt
                lastEnd = max(lastEnd, resolvedEndMs(for: item))
            } else {
                appendCurrentSegment()
                current = item
                segmentKey = itemKey
                segStart = item.startedAtMs
                lastEnd = resolvedEndMs(for: item)
                nonAppAccum = 0
            }
        }

        appendCurrentSegment()
    }

    private func rebuildAscCache() {
        timesAsc = metas.map(\.startedAtMs).sorted()
    }

    private func defaultMsPerPoint() -> Double {
        let span = max(1, Double(max(0, maxTimeMs - minTimeMs)))
        return max(span / 5000.0, 1.0)
    }

    func resolvedEndMs(for meta: SnapshotMeta) -> Int64 {
        if let endedAtMs = meta.endedAtMs {
            return max(meta.startedAtMs, endedAtMs)
        }
        if let audioDurationMs = meta.audioDurationMs {
            return meta.startedAtMs + max(0, audioDurationMs)
        }
        return meta.startedAtMs
    }

    func audioMeta(overlapping timeMs: Int64) -> SnapshotMeta? {
        metas
            .filter { $0.captureKind == .audio }
            .first { meta in
                let endMs = resolvedEndMs(for: meta)
                return timeMs >= meta.startedAtMs && timeMs <= endMs
            }
    }

    func indexNearest(to timeMs: Int64,
                      preferredCaptureKind: CaptureKind? = nil,
                      visibleCaptureKinds: Set<CaptureKind>? = nil,
                      startedAtRange: ClosedRange<Int64>? = nil) -> Int? {
        guard !metas.isEmpty else { return nil }

        let allowedKinds = visibleCaptureKinds?.isEmpty == false
            ? visibleCaptureKinds!
            : Set(CaptureKind.allCases)

        var candidateIndices = metas.indices.filter { allowedKinds.contains(metas[$0].captureKind) }
        if let startedAtRange {
            candidateIndices = candidateIndices.filter { startedAtRange.contains(metas[$0].startedAtMs) }
        }
        if candidateIndices.isEmpty {
            candidateIndices = Array(metas.indices)
        }

        if let preferredCaptureKind {
            let preferredIndices = candidateIndices.filter { metas[$0].captureKind == preferredCaptureKind }
            if !preferredIndices.isEmpty {
                candidateIndices = preferredIndices
            }
        }

        return candidateIndices.min { lhs, rhs in
            let lhsDelta = abs(metas[lhs].startedAtMs - timeMs)
            let rhsDelta = abs(metas[rhs].startedAtMs - timeMs)
            if lhsDelta == rhsDelta {
                return metas[lhs].startedAtMs > metas[rhs].startedAtMs
            }
            return lhsDelta < rhsDelta
        }
    }

    func jump(to timeMs: Int64,
              preferredCaptureKind: CaptureKind? = nil,
              visibleCaptureKinds: Set<CaptureKind>? = nil) {
        if let idx = indexNearest(to: timeMs,
                                  preferredCaptureKind: preferredCaptureKind,
                                  visibleCaptureKinds: visibleCaptureKinds) {
            selectedIndex = idx
        }
    }

    func openSnapshot(id: Int64, anchorStartedAtMs: Int64? = nil, spanMs: Int64 = 6 * 60 * 60 * 1000) {
        followLatest = false
        requestToken &+= 1
        let token = requestToken
        isLoading = true

        let appIds = selectedAppBundleIds.isEmpty ? nil : Array(selectedAppBundleIds)
        let captureKinds = selectedCaptureKinds.isEmpty ? nil : Array(selectedCaptureKinds)
        let audioSourceKinds = selectedAudioSourceKinds.isEmpty ? nil : Array(selectedAudioSourceKinds)

        DispatchQueue.global(qos: .userInitiated).async { [spanMs, appIds, captureKinds, audioSourceKinds] in
            let anchorTime: Int64?
            if let anchorStartedAtMs {
                anchorTime = anchorStartedAtMs
            } else {
                anchorTime = (try? DB.shared.snapshotMetaById(id))?.startedAtMs
            }

            guard let anchorTime else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, token == self.requestToken else { return }
                    self.isLoading = false
                }
                return
            }

            let start = max(0, anchorTime - spanMs)
            let end = anchorTime + spanMs
            let list = (try? DB.shared.latestMetas(
                limit: 5000,
                appBundleIds: appIds,
                startMs: start,
                endMs: end,
                captureKinds: captureKinds,
                audioSourceKinds: audioSourceKinds
            )) ?? []
            let sorted = list.sorted { $0.startedAtMs > $1.startedAtMs }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard token == self.requestToken else { return }
                self.metas = sorted
                self.selectedIndex = self.metas.firstIndex(where: { $0.id == id }) ?? (self.metas.isEmpty ? -1 : 0)
                self.rebuildAscCache()
                self.refreshSegments()
                self.isLoading = false
            }
        }
    }

    func prev() {
        if selectedIndex + 1 < metas.count { selectedIndex += 1 }
    }

    func next() {
        if selectedIndex - 1 >= 0 { selectedIndex -= 1 }
    }

    func deleteSnapshot(id: Int64) {
        guard metas.contains(where: { $0.id == id }) else { return }

        requestToken &+= 1
        let token = requestToken
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let deletionSucceeded: Bool
            do {
                try DB.shared.deleteSnapshot(id: id)
                deletionSucceeded = true
            } catch {
                deletionSucceeded = false
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard token == self.requestToken else { return }
                self.isLoading = false

                guard deletionSucceeded else {
                    NSSound.beep()
                    self.load()
                    return
                }

                self.applyDeletedSnapshotToCurrentState(id: id)
            }
        }
    }

    private func applyDeletedSnapshotToCurrentState(id: Int64) {
        guard let idx = metas.firstIndex(where: { $0.id == id }) else {
            load()
            return
        }

        metas.remove(at: idx)
        if metas.isEmpty {
            selectedIndex = -1
        } else {
            selectedIndex = min(idx, metas.count - 1)
        }
        rebuildAscCache()
        refreshSegments()
    }
}

private struct TimelineSegmentKey: Hashable {
    let appBundleId: String?
    let appName: String?
    let captureKind: CaptureKind
    let audioSourceKind: AudioSourceKind?

    init(meta: SnapshotMeta) {
        appBundleId = meta.appBundleId
        appName = meta.appName
        captureKind = meta.captureKind
        audioSourceKind = meta.audioSourceKind
    }
}

struct TimelineSegment: Hashable {
    let appBundleId: String?
    let appName: String?
    let captureKind: CaptureKind
    let audioSourceKind: AudioSourceKind?
    let startMs: Int64
    let endMs: Int64
    let toleratedNonAppMs: Int64
    let actualNonAppMs: Int64
}
