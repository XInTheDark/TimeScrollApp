import Foundation
import SwiftUI
import AppKit

@MainActor
final class TimelineModel: ObservableObject {
    // Filters
    @Published var query: String = ""
    @Published var selectedAppBundleIds: Set<String> = []
    @Published var startMs: Int64? = nil
    @Published var endMs: Int64? = nil

    // Data
    @Published private(set) var metas: [SnapshotMeta] = [] // DESC by time
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
    // Loading state for timeline fetch
    @Published var isLoading: Bool = false

    private var timesAsc: [Int64] = []
    private var requestToken: Int = 0

    var minTimeMs: Int64 { metas.last?.startedAtMs ?? 0 }
    var maxTimeMs: Int64 { metas.first?.startedAtMs ?? 0 }

    init() {
        // Always start the session with the overlay in the default position.
        // Users can drag it during a session, but on new window/app launch it resets.
        overlayOffsetX = 0
        overlayOffsetY = 220
    }
    var selected: SnapshotMeta? { metas.indices.contains(selectedIndex) ? metas[selectedIndex] : nil }

    func load(limit: Int = 1000) {
        requestToken &+= 1
        let token = requestToken
        isLoading = true
        // Allow UI to update and show the spinner
        Task { @MainActor in await Task.yield() }

        // Capture inputs on the main actor; background work must not touch main-actor singletons.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSelectedId = selected?.id
        let settings = SettingsStore.shared
        let useAI = settings.aiEmbeddingsEnabled && settings.aiModeOn && EmbeddingService.shared.dim > 0
        let ia = settings.intelligentAccuracy
        let fuzz = settings.fuzziness
        let appIds = selectedAppBundleIds.isEmpty ? nil : Array(selectedAppBundleIds)
        let start = startMs
        let end = endMs
        DispatchQueue.global(qos: .userInitiated).async { [limit, trimmed, appIds, start, end, useAI, fuzz, ia] in
            let searchSvc = SearchService()
            let list: [SnapshotMeta]
            if trimmed.isEmpty {
                list = searchSvc.latestMetas(limit: limit,
                                             appBundleIds: appIds,
                                             startMs: start,
                                             endMs: end)
            } else if useAI {
                list = searchSvc.searchAIMetas(trimmed,
                                               appBundleIds: appIds,
                                               startMs: start,
                                               endMs: end,
                                               limit: limit)
            } else {
                list = searchSvc.searchMetas(trimmed,
                                             fuzziness: fuzz,
                                             intelligentAccuracy: ia,
                                             appBundleIds: appIds,
                                             startMs: start,
                                             endMs: end,
                                             limit: limit)
            }

            let sorted = list.sorted { $0.startedAtMs > $1.startedAtMs }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
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
        // Treat long idle periods as a new strip even if the user returns to the same app.
        // This keeps the visual timeline honest and gives compressed mode a real gap to shrink.
        let inactivityBreakMs: Int64 = 60_000

        var segApp = asc.first!.appBundleId
        var segName = asc.first!.appName
        var segStart = asc.first!.startedAtMs
        var lastTime = segStart
        var nonAppAccum: Int64 = 0
        if asc.count > 1 {
            for i in 1..<asc.count {
                let cur = asc[i]
                let prev = asc[i - 1]
                let dt = max(0, cur.startedAtMs - prev.startedAtMs)
                if dt > inactivityBreakMs {
                    segments.append(TimelineSegment(appBundleId: segApp,
                                                    appName: segName,
                                                    startMs: segStart,
                                                    endMs: lastTime,
                                                    toleratedNonAppMs: Int64((0.10 * Double(lastTime - segStart)).rounded(.up)),
                                                    actualNonAppMs: nonAppAccum))
                    segApp = cur.appBundleId
                    segName = cur.appName
                    segStart = cur.startedAtMs
                    lastTime = cur.startedAtMs
                    nonAppAccum = 0
                } else if cur.appBundleId == segApp {
                    lastTime = cur.startedAtMs
                } else {
                    let provisional = max(1, cur.startedAtMs - segStart)
                    let allowed = Int64((0.10 * Double(provisional)).rounded(.up))
                    if nonAppAccum + dt <= allowed {
                        nonAppAccum += dt
                        lastTime = cur.startedAtMs
                    } else {
                        segments.append(TimelineSegment(appBundleId: segApp,
                                                        appName: segName,
                                                        startMs: segStart,
                                                        endMs: lastTime,
                                                        toleratedNonAppMs: Int64((0.10 * Double(lastTime - segStart)).rounded(.up)),
                                                        actualNonAppMs: nonAppAccum))
                        // start new
                        segApp = cur.appBundleId
                        segName = cur.appName
                        segStart = cur.startedAtMs
                        lastTime = cur.startedAtMs
                        nonAppAccum = 0
                    }
                }
            }
        }
        segments.append(TimelineSegment(appBundleId: segApp,
                                        appName: segName,
                                        startMs: segStart,
                                        endMs: lastTime,
                                        toleratedNonAppMs: Int64((0.10 * Double(lastTime - segStart)).rounded(.up)),
                                        actualNonAppMs: nonAppAccum))
    }

    private func rebuildAscCache() {
        timesAsc = metas.map { $0.startedAtMs }.sorted()
    }

    private func defaultMsPerPoint() -> Double {
        let span = max(1, Double(max(0, maxTimeMs - minTimeMs)))
        return max(span / 5000.0, 1.0) // at least 1 ms/pt
    }

    func indexNearest(to timeMs: Int64) -> Int? {
        guard !metas.isEmpty else { return nil }
        let times = timesAsc
        if times.isEmpty { return 0 }
        var lo = 0
        var hi = times.count - 1
        var mid = 0
        while lo <= hi {
            mid = (lo + hi) / 2
            let t = times[mid]
            if t == timeMs { break }
            if t < timeMs { lo = mid + 1 } else { hi = mid - 1 }
        }
        let c1 = max(0, min(times.count - 1, lo))
        let c2 = max(0, min(times.count - 1, hi))
        let bestAscIndex = abs(times[c1] - timeMs) <= abs(times[c2] - timeMs) ? c1 : c2
        let targetTime = times[bestAscIndex]
        // Convert to DESC index by matching time (multiple equal times are rare)
        if let idx = metas.firstIndex(where: { $0.startedAtMs == targetTime }) {
            return idx
        }
        // Fallback linear
        var bestIdx = 0
        var bestDelta = Int64.max
        for (i, m) in metas.enumerated() {
            let d = abs(m.startedAtMs - timeMs)
            if d < bestDelta { bestDelta = d; bestIdx = i }
        }
        return bestIdx
    }

    func jump(to timeMs: Int64) {
        if let idx = indexNearest(to: timeMs) {
            selectedIndex = idx
        }
    }

    // Open a specific snapshot by id by loading a time window around it and selecting it.
    func openSnapshot(id: Int64, anchorStartedAtMs: Int64? = nil, spanMs: Int64 = 6 * 60 * 60 * 1000) {
        // User-initiated navigation should pause live-follow so the view doesn't snap back.
        followLatest = false
        requestToken &+= 1
        let token = requestToken
        isLoading = true
        let appIds = selectedAppBundleIds.isEmpty ? nil : Array(selectedAppBundleIds)
        DispatchQueue.global(qos: .userInitiated).async { [spanMs, appIds] in
            let anchorTime: Int64?
            if let anchorStartedAtMs {
                anchorTime = anchorStartedAtMs
            } else {
                anchorTime = (try? DB.shared.snapshotMetaById(id))?.startedAtMs
            }

            guard let anchorTime else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, token == self.requestToken else { return }
                    self.isLoading = false
                }
                return
            }

            let s = max(0, anchorTime - spanMs)
            let e = anchorTime + spanMs
            let list = (try? DB.shared.latestMetas(limit: 5000,
                                                   appBundleIds: appIds,
                                                   startMs: s,
                                                   endMs: e)) ?? []
            let sorted = list.sorted { $0.startedAtMs > $1.startedAtMs }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard token == self.requestToken else { return }
                self.metas = sorted
                self.selectedIndex = self.metas.firstIndex(where: { $0.id == id }) ?? (self.metas.isEmpty ? -1 : 0)
                self.rebuildAscCache()
                self.refreshSegments()
                self.isLoading = false
            }
        }
    }

    func prev() { if selectedIndex + 1 < metas.count { selectedIndex += 1 } }
    func next() { if selectedIndex - 1 >= 0 { selectedIndex -= 1 } }

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
                guard let self = self else { return }
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
            // Keep selection at same visual position if possible
            let newIdx = min(idx, metas.count - 1)
            selectedIndex = newIdx
        }
        rebuildAscCache()
        refreshSegments()
    }
}

struct TimelineSegment: Hashable {
    let appBundleId: String?
    let appName: String?
    let startMs: Int64
    let endMs: Int64
    let toleratedNonAppMs: Int64
    let actualNonAppMs: Int64
}
