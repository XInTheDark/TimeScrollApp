import Foundation
import ScreenCaptureKit
import CoreMedia

final class CaptureManager: NSObject {
    private var streams: [SCStream] = []
    private var streamConfigurations: [SCStreamConfiguration] = []
    private var configuredProbeIntervals: [Double] = []
    private var outputs: [FrameOutput] = []
    private var capturedDisplays: [SCDisplay] = []
    private let outputQueue = DispatchQueue(label: "TimeScroll.Capture.Output")
    private let streamDelegate = StreamDelegate()
    private let onSnapshot: (URL) -> Void

    init(onSnapshot: @escaping (URL) -> Void) {
        self.onSnapshot = onSnapshot
        super.init()
    }

    func start() async throws {
        let content = try await shareableContent()

        // Determine which displays to capture based on settings (background-safe via UserDefaults)
        let d = UserDefaults.standard
        let modeRaw = d.string(forKey: "settings.captureDisplayMode") ?? "first"
        let captureAll = (modeRaw == "all")
        let displays: [SCDisplay] = captureAll ? content.displays : (content.displays.first.map { [$0] } ?? [])
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
        for stream in streams {
            try await stream.startCapture()
        }
    }

    func stop() async {
        for stream in streams {
            try? await stream.stopCapture()
        }
        streams.removeAll()
        streamConfigurations.removeAll()
        configuredProbeIntervals.removeAll()
        outputs.removeAll()
        capturedDisplays.removeAll()
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
    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private func excludedApplications(bundleIds: Set<String>, content: SCShareableContent) -> [SCRunningApplication] {
        guard !bundleIds.isEmpty else { return [] }
        return content.applications.filter { bundleIds.contains($0.bundleIdentifier) }
    }

    private func filterFor(display: SCDisplay, apps: [SCRunningApplication]) -> SCContentFilter {
        SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
    }

    @MainActor
    func updateExclusions(with bundleIds: [String]) async {
        guard !streams.isEmpty else { return }
        do {
            let content = try await shareableContent()
            let apps = excludedApplications(bundleIds: Set(bundleIds), content: content)
            await applyExclusions(apps: apps)
        } catch {
            // ignore
        }
    }

    @MainActor
    private func applyExclusions(apps: [SCRunningApplication]) async {
        for (index, stream) in streams.enumerated() {
            guard capturedDisplays.indices.contains(index) else { continue }
            let display = capturedDisplays[index]
            let filter = filterFor(display: display, apps: apps)
            do {
                try await stream.updateContentFilter(filter)
            } catch {
                // ignore
            }
        }
    }
}

final class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        #if DEBUG
        print("SCStream stopped with error:", error)
        #endif
    }
}
