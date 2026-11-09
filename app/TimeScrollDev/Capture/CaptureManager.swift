import Foundation
import ScreenCaptureKit
import CoreMedia

final class CaptureManager: NSObject {
    private var streams: [SCStream] = []
    private var streamConfigurations: [SCStreamConfiguration] = []
    private var configuredProbeIntervals: [Double] = []
    private var outputs: [FrameOutput] = []
    private var capturedDisplays: [SCDisplay] = []
    /// Every display ScreenCaptureKit offered when capture started, whether or not it is captured.
    /// Displays are enumerated only on start, so a monitor plugged in later is missed until a restart.
    private var availableDisplayIDs: Set<CGDirectDisplayID> = []
    private let outputQueue = DispatchQueue(label: "TimeScroll.Capture.Output")
    private let streamDelegate = StreamDelegate()
    private var appSwitchObserver: AppSwitchObserver?
    private var excludedAppObserver: ExcludedAppObserver?
    private lazy var excludedAppGate = ExcludedAppGate { [weak self] in
        Task { @MainActor [weak self] in
            await self?.refreshExclusions()
        }
    }
    private var appliedExcludedPIDs: Set<pid_t> = []
    private var appliedPrivateWindowPlan = PrivateWindowFilterPlan.empty
    private var privateBrowserObserver: PrivateBrowserObserver?
    private var isRefreshingExclusions = false
    private var needsAnotherExclusionRefresh = false
    private let onSnapshot: (URL) -> Void

    init(onSnapshot: @escaping (URL) -> Void) {
        self.onSnapshot = onSnapshot
        super.init()
    }

    func start() async throws {
        let content = try await shareableContent()

        // Determine which displays to capture based on settings (background-safe via UserDefaults)
        let d = UserDefaults.standard
        let mode = SettingsStore.DisplayCaptureMode(rawValue: d.string(forKey: "settings.captureDisplayMode") ?? "") ?? SettingsStore.defaultDisplayCaptureMode
        // "Main" is the display with the menu bar; SCShareableContent's order is arbitrary.
        let mainDisplay = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        let displays: [SCDisplay] = mode == .first ? (mainDisplay.map { [$0] } ?? []) : content.displays
        let activeDisplay = mode == .active ? ActiveDisplayTracker(displayIDs: displays.map(\.displayID)) : nil
        guard !displays.isEmpty else { throw NSError(domain: "TS", code: -2) }
        let baseCaptureInterval = {
            let value = d.double(forKey: "settings.captureMinInterval")
            return value > 0 ? value : SettingsStore.defaultCaptureMinInterval
        }()
        let initialProbeInterval = Self.probeInterval(forCaptureInterval: baseCaptureInterval)

        // Capture scale is user-configurable; default 0.8
        let capScale = (d.object(forKey: "settings.captureScale") != nil) ? d.double(forKey: "settings.captureScale") : SettingsStore.defaultCaptureScale
        let scale = max(0.5, min(capScale, 1.0))

        // Configure and start a stream per display
        var newStreams: [SCStream] = []
        var newConfigs: [SCStreamConfiguration] = []
        var newProbeIntervals: [Double] = []
        var newOutputs: [FrameOutput] = []
        // Compute initial exclusion set once and reuse per display
        let blacklistBundleSet = Set((UserDefaults.standard.array(forKey: "settings.blacklistBundleIds") as? [String]) ?? [])
        let blacklistApps: [SCRunningApplication] = excludedApplications(bundleIds: blacklistBundleSet, content: content)
        appliedExcludedPIDs = Set(blacklistApps.map(\.processID))
        excludedAppGate.updateCovered(appliedExcludedPIDs,
                                      running: ExcludedAppObserver.runningPIDs(bundleIds: blacklistBundleSet),
                                      at: .zero)
        excludedAppObserver?.invalidate()
        excludedAppObserver = ExcludedAppObserver { [excludedAppGate] in
            excludedAppGate.updateRunning(ExcludedAppObserver.runningPIDs(bundleIds: ExcludedAppObserver.storedBundleIds()))
        }
        appliedPrivateWindowPlan = .empty
        PrivateWindowTracker.shared.reset()
        PrivateWindowTracker.shared.setFilterStaleHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshExclusions()
            }
        }
        PrivateWindowTracker.shared.updateBrowsers(PrivateBrowserObserver.runningBrowsers(excluding: blacklistBundleSet))
        privateBrowserObserver?.invalidate()
        privateBrowserObserver = PrivateBrowserObserver {
            PrivateWindowTracker.shared.updateBrowsers(
                PrivateBrowserObserver.runningBrowsers(excluding: ExcludedAppObserver.storedBundleIds()))
        }

        for display in displays {
            let streamIndex = newStreams.count
            let cfg = SCStreamConfiguration()
            cfg.queueDepth = 8
            // NV12 saves bandwidth; if you see issues in your stack, switch back to BGRA.
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            cfg.showsCursor = false
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.minimumFrameInterval = CMTime(seconds: initialProbeInterval, preferredTimescale: 600)

            // Downscale at the source to cut energy cost
            let w = Int(Double(display.width) * scale)
            let h = Int(Double(display.height) * scale)
            cfg.width = max(640, w)
            cfg.height = max(360, h)
            cfg.scalesToFit = true

            // Build a content filter that excludes any blacklisted applications
            let filter = filterFor(display: display, apps: blacklistApps)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: streamDelegate)
            let output = FrameOutput(
                onSnapshot: onSnapshot,
                hevcStore: HEVCVideoStore(namespace: String(display.displayID)),
                displayBounds: CGDisplayBounds(display.displayID),
                isActiveDisplay: activeDisplay.map { tracker in { tracker.isActive(display.displayID) } },
                excludedAppGate: excludedAppGate,
                onProbeIntervalChanged: { [weak self] probeInterval in
                    self?.scheduleProbeIntervalUpdate(probeInterval, for: streamIndex)
                }
            )
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            newStreams.append(stream)
            newConfigs.append(cfg)
            newProbeIntervals.append(initialProbeInterval)
            newOutputs.append(output)
        }

        // Assign to properties so they are retained during start
        streams = newStreams
        streamConfigurations = newConfigs
        configuredProbeIntervals = newProbeIntervals
        outputs = newOutputs
        capturedDisplays = displays
        availableDisplayIDs = Set(content.displays.map(\.displayID))
        appSwitchObserver?.invalidate()
        // Outputs are only touched on outputQueue, where their sample handlers also run.
        nonisolated(unsafe) let switchOutputs = newOutputs
        appSwitchObserver = AppSwitchObserver { [outputQueue] in
            outputQueue.async {
                for output in switchOutputs { output.noteAppSwitch() }
            }
        }
        for stream in streams {
            try await stream.startCapture()
        }
    }

    func stop() async {
        appSwitchObserver?.invalidate()
        appSwitchObserver = nil
        excludedAppObserver?.invalidate()
        excludedAppObserver = nil
        privateBrowserObserver?.invalidate()
        privateBrowserObserver = nil
        for stream in streams {
            try? await stream.stopCapture()
        }
        excludedAppGate.reset()
        PrivateWindowTracker.shared.setFilterStaleHandler(nil)
        PrivateWindowTracker.shared.reset()
        appliedPrivateWindowPlan = .empty
        flushWriters()
        streams.removeAll()
        streamConfigurations.removeAll()
        configuredProbeIntervals.removeAll()
        outputs.removeAll()
        capturedDisplays.removeAll()
        availableDisplayIDs.removeAll()
    }

    /// Whether ScreenCaptureKit now offers a different set of displays than when capture started.
    /// Compares ScreenCaptureKit with itself, so mirrored or sleeping displays cannot cause false positives.
    func displaysChangedSinceStart() async -> Bool {
        guard !availableDisplayIDs.isEmpty,
              let content = try? await shareableContent() else { return false }
        return Set(content.displays.map(\.displayID)) != availableDisplayIDs
    }

    /// Best-effort fallback for process termination after normal shutdown was skipped.
    func flushWriters() {
        for output in outputs {
            output.shutdown()
        }
    }

    private static func probeInterval(forCaptureInterval interval: Double) -> Double {
        min(5.0, max(0.5, interval / 2.0))
    }

    private func scheduleProbeIntervalUpdate(_ seconds: Double, for index: Int) {
        Task { @MainActor [weak self] in
            await self?.applyProbeIntervalUpdate(seconds, for: index)
        }
    }

    @MainActor
    private func applyProbeIntervalUpdate(_ seconds: Double, for index: Int) async {
        guard streams.indices.contains(index), streamConfigurations.indices.contains(index), configuredProbeIntervals.indices.contains(index) else {
            return
        }
        let clamped = min(5.0, max(0.5, seconds))
        let current = configuredProbeIntervals[index]
        if abs(current - clamped) < 0.25 {
            return
        }
        let config = streamConfigurations[index]
        config.minimumFrameInterval = CMTime(seconds: clamped, preferredTimescale: 600)
        do {
            try await streams[index].updateConfiguration(config)
            configuredProbeIntervals[index] = clamped
        } catch {
            // Ignore transient configuration update failures; the stream keeps running.
        }
    }

    // MARK: - Helpers (DRY)
    /// Includes off-screen windows: an on-screen-only list omits excluded apps that are hidden or on
    /// another Space, and they would then be captured once they appear.
    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    private func excludedApplications(bundleIds: Set<String>, content: SCShareableContent) -> [SCRunningApplication] {
        guard !bundleIds.isEmpty else { return [] }
        return content.applications.filter { bundleIds.contains($0.bundleIdentifier) }
    }

    private func filterFor(display: SCDisplay, apps: [SCRunningApplication], exceptingWindows: [SCWindow] = []) -> SCContentFilter {
        SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: exceptingWindows)
    }

    /// Rebuilds the stream filters from the stored list. Concurrent calls coalesce, and the last
    /// pass always sees the latest list.
    @MainActor
    func refreshExclusions() async {
        guard !streams.isEmpty else { return }
        if isRefreshingExclusions {
            needsAnotherExclusionRefresh = true
            return
        }
        isRefreshingExclusions = true
        defer { isRefreshingExclusions = false }
        repeat {
            needsAnotherExclusionRefresh = false
            await refreshExclusionsOnce()
        } while needsAnotherExclusionRefresh
    }

    @MainActor
    private func refreshExclusionsOnce() async {
        let bundleIds = ExcludedAppObserver.storedBundleIds()
        let running = ExcludedAppObserver.runningPIDs(bundleIds: bundleIds)
        do {
            let content = try await shareableContent()
            let apps = excludedApplications(bundleIds: bundleIds, content: content)
            let pids = Set(apps.map(\.processID))
            let tracker = PrivateWindowTracker.shared
            tracker.updateBrowsers(PrivateBrowserObserver.runningBrowsers(excluding: bundleIds))
            tracker.retain(existing: Set(content.windows.map(\.windowID)))
            let plan = tracker.filterPlan(listedPIDs: Set(content.applications.map(\.processID)))
            // The filter stays as it was if a stream refuses the update, so frames keep being checked.
            if pids != appliedExcludedPIDs || plan != appliedPrivateWindowPlan {
                let browsers = content.applications.filter { plan.browserPIDs.contains($0.processID) && !pids.contains($0.processID) }
                let excepted = content.windows.filter { plan.exceptedWindowIDs.contains($0.windowID) }
                guard await applyExclusions(apps: apps + browsers, exceptingWindows: excepted) else { return }
                appliedExcludedPIDs = pids
                appliedPrivateWindowPlan = plan
            }
            let appliedAt = CMClockGetTime(CMClockGetHostTimeClock())
            tracker.filterApplied(plan, at: appliedAt)
            excludedAppGate.updateCovered(pids, running: running, at: appliedAt)
        } catch {
            excludedAppGate.updateRunning(running)
        }
    }

    @MainActor
    private func applyExclusions(apps: [SCRunningApplication], exceptingWindows: [SCWindow]) async -> Bool {
        var succeeded = true
        for (index, stream) in streams.enumerated() {
            guard capturedDisplays.indices.contains(index) else { continue }
            let display = capturedDisplays[index]
            let filter = filterFor(display: display, apps: apps, exceptingWindows: exceptingWindows)
            do {
                try await stream.updateContentFilter(filter)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }
}

final class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        #if DEBUG
        print("SCStream stopped with error:", error)
        #endif
        // Without this the app keeps showing itself as recording after replayd crashes.
        let userStopped = (error as? SCStreamError)?.code == .userStopped
        Task { @MainActor in
            AppState.shared.screenStreamDidStop(userStopped: userStopped)
        }
    }
}
