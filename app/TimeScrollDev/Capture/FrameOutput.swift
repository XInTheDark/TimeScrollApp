import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

final class FrameOutput: NSObject, SCStreamOutput {
    // Cadence gating
    var lastEvaluatedPTS: CMTime = .invalid
    var lastPersistedPTS: CMTime = .invalid
    private let evaluationGate = DispatchSemaphore(value: 1)

    // Adaptive interval
    var currentInterval: CFTimeInterval = 0
    var baseInterval: CFTimeInterval {
        let v = UserDefaults.standard.double(forKey: "settings.captureMinInterval")
        return CFTimeInterval(v > 0 ? v : SettingsStore.defaultCaptureMinInterval)
    }
    var maxInterval: CFTimeInterval {
        let v = UserDefaults.standard.double(forKey: "settings.adaptiveMaxInterval")
        return CFTimeInterval(v > 0 ? v : SettingsStore.defaultAdaptiveMaxInterval)
    }

    // Work infra
    let workQueue = DispatchQueue(label: "TimeScroll.Capture.Work", qos: .utility)
    // Dedicated serial queue for OCR so it does not contend with encode path
    let ocrQueue = DispatchQueue(label: "TimeScroll.OCR", qos: .utility)
    let onSnapshot: (URL) -> Void
    let encoder = ImageEncoder()
    let hasher = ImageHasher()
    let hevcStore: HEVCVideoStore

    // Dedup/adaptive
    var lastHash: UInt64?
    var stableCount: Int = 0
    var lastCapturedFingerprint: (id: Int64, fingerprint: TextFingerprint)?

    // Thermal governance
    var lastThermalState: ProcessInfo.ThermalState = .nominal
    var lastThermalAdjustAt: TimeInterval = 0
    var suppressPostersUntil: TimeInterval = 0
    var lastReportedProbeInterval: CFTimeInterval = 0

    var ocrService: OCRService?
    let onProbeIntervalChanged: (CFTimeInterval) -> Void

    enum PersistOutcome {
        case saved(url: URL, bytes: Int64, width: Int, height: Int, thumbPath: String?)
        case queuedWhileLocked
        case skippedWhileLocked
    }

    init(onSnapshot: @escaping (URL) -> Void,
         hevcStore: HEVCVideoStore,
         onProbeIntervalChanged: @escaping (CFTimeInterval) -> Void = { _ in }) {
        self.onSnapshot = onSnapshot
        self.hevcStore = hevcStore
        self.onProbeIntervalChanged = onProbeIntervalChanged
        super.init()
        currentInterval = baseInterval
        reportProbeIntervalIfNeeded(force: true)
    }

    func desiredProbeInterval() -> CFTimeInterval {
        let desired = currentInterval / 2.0
        return min(5.0, max(0.5, desired))
    }

    func reportProbeIntervalIfNeeded(force: Bool = false) {
        let desired = desiredProbeInterval()
        if !force, abs(desired - lastReportedProbeInterval) < 0.25 { return }
        lastReportedProbeInterval = desired
        onProbeIntervalChanged(desired)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, let pixelBuffer = sb.imageBuffer else { return }
        guard evaluationGate.wait(timeout: .now()) == .success else { return }
        var handedOff = false
        defer { if !handedOff { evaluationGate.signal() } }

        // Lightweight thermal governance check (every ~1s)
        applyThermalGovernorIfNeeded()

        // Clamp currentInterval to reflect any preference changes immediately
        let bInt = baseInterval
        let mInt = maxInterval
        if currentInterval < bInt || currentInterval > mInt {
            currentInterval = min(mInt, max(bInt, currentInterval))
            reportProbeIntervalIfNeeded(force: true)
        }

        // Gate evaluation cadence by PTS
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if lastEvaluatedPTS.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastEvaluatedPTS))
            if delta < currentInterval { return }
        }
        let processing = UserDefaults.standard.string(forKey: "settings.textProcessingMode") ?? SettingsStore.defaultTextProcessingMode.rawValue
        if processing == SettingsStore.TextProcessingMode.ocr.rawValue, Indexer.shared.isOCRCoolingDown { return }

        // Privacy handled via SCContentFilter exclusions at the stream level.

        lastEvaluatedPTS = pts

        // Snapshot background-readable settings
        let defaults = UserDefaults.standard
        let fmtRaw = defaults.string(forKey: "settings.storageFormat") ?? SettingsStore.defaultStorageFormat.rawValue
        let fmt = SettingsStore.StorageFormat(rawValue: fmtRaw) ?? SettingsStore.defaultStorageFormat
        let maxEdge = (defaults.object(forKey: "settings.maxLongEdge") != nil) ? defaults.integer(forKey: "settings.maxLongEdge") : SettingsStore.defaultMaxLongEdge
        let quality = (defaults.object(forKey: "settings.lossyQuality") != nil) ? defaults.double(forKey: "settings.lossyQuality") : SettingsStore.defaultLossyQuality
        let dedupEnabled = (defaults.object(forKey: "settings.dedupEnabled") != nil) ? defaults.bool(forKey: "settings.dedupEnabled") : true
        let thr = (defaults.object(forKey: "settings.dedupHammingThreshold") != nil) ? defaults.integer(forKey: "settings.dedupHammingThreshold") : SettingsStore.defaultDedupHammingThreshold
        let adaptive = (defaults.object(forKey: "settings.adaptiveSampling") != nil) ? defaults.bool(forKey: "settings.adaptiveSampling") : SettingsStore.defaultAdaptiveSampling
        let vaultOn = (defaults.object(forKey: "settings.vaultEnabled") != nil) ? defaults.bool(forKey: "settings.vaultEnabled") : false
        let allowWhileLocked = (defaults.object(forKey: "settings.captureWhileLocked") != nil) ? defaults.bool(forKey: "settings.captureWhileLocked") : true
        let unlockedFlag = defaults.bool(forKey: "vault.isUnlocked")

        // When capture while locked is disabled, avoid hashing or encoding frames.
        // Keep lastHash unchanged so the current screen is captured after unlock.
        if vaultOn && !unlockedFlag && !allowWhileLocked {
            return
        }

        // IMPORTANT: Compute hash directly from the pixel buffer (cheap, uses CI) before making any CGImage.
        var hashVal: UInt64 = 0
        if dedupEnabled {
            hashVal = hasher.hash64(pixelBuffer: pixelBuffer)
            if let prev = lastHash {
                let hamming = ImageHasher.hamming(prev, hashVal)
                if hamming <= thr {
                    // For HEVC we still append frames to the segment to keep the video continuous,
                    // but we skip DB/metadata work for unchanged frames.
                    if fmt == .hevc {
                        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
                        if !vaultOn || (vaultOn && (unlockedFlag ? true : allowWhileLocked)) {
                            self.hevcStore.append(pixelBuffer: pixelBuffer, timestampMs: tsMs, encrypt: vaultOn)
                        }
                    }
                    if adaptive {
                        stableCount += 1
                        currentInterval = min(maxInterval, baseInterval * CFTimeInterval(pow(1.5, Double(stableCount))))
                        reportProbeIntervalIfNeeded()
                    }
                    return
                }
            }
        }

        // Retain the pixel buffer to safely use it across queues.
        let retainedPixelBuffer = Unmanaged.passRetained(pixelBuffer)
        handedOff = true
        let gate = evaluationGate
        workQueue.async { [weak self] in
            defer { gate.signal() }
            guard let self else {
                retainedPixelBuffer.release()
                return
            }
            // Persist directly from the pixel buffer to avoid CGImage creation
            let pb = retainedPixelBuffer.takeUnretainedValue()
            do {
                let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
                // App metadata from tracker (no main-thread hop)
                let info = AppActivityTracker.shared.current()
                let bid = info.bundleId
                let name = info.name

                let outcome = try self.persist(
                    pixelBuffer: pb,
                    fmt: fmt,
                    tsMs: tsMs,
                    maxEdge: maxEdge,
                    quality: quality,
                    vaultOn: vaultOn,
                    allowWhileLocked: allowWhileLocked,
                    hash64: hashVal,
                    appBundleId: bid,
                    appName: name
                )

                switch outcome {
                case .queuedWhileLocked:
                    // The encrypted snapshot and its metadata are safely queued. Treat it
                    // as an accepted capture so an unchanged locked screen is deduplicated.
                    self.lastHash = hashVal
                    self.stableCount = 0
                    self.currentInterval = self.baseInterval
                    self.lastPersistedPTS = pts
                    self.reportProbeIntervalIfNeeded()
                    retainedPixelBuffer.release()
                    return
                case .skippedWhileLocked:
                    retainedPixelBuffer.release()
                    return
                case let .saved(url, bytes, width, height, thumbPath):
                    let rowId = try Indexer.shared.insertStub(
                        startedAtMs: tsMs,
                        savedURL: url,
                        extra: Indexer.SnapshotExtraMeta(
                            bytes: bytes,
                            width: width,
                            height: height,
                            format: fmt.dbFormatString,
                            hash64: Int64(bitPattern: hashVal)
                        ),
                        appBundleId: bid,
                        appName: name,
                        thumbPath: thumbPath
                    )

                    // Notify UI before OCR to avoid races
                    DispatchQueue.main.async { self.onSnapshot(url) }

                    // Reset adaptive state after a real persist
                    self.lastHash = hashVal
                    self.stableCount = 0
                    self.currentInterval = self.baseInterval
                    self.lastPersistedPTS = pts
                    self.reportProbeIntervalIfNeeded()

                    self.processText(snapshotId: rowId, retainedPixelBuffer: retainedPixelBuffer)
                }
            } catch {
                retainedPixelBuffer.release()
                // swallow for now
            }
        }
    }

    func shutdown() {
        workQueue.sync {}
        ocrQueue.sync {}
        hevcStore.shutdown()
    }
}
