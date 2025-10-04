import Foundation
import ScreenCaptureKit
import CoreImage
import CoreVideo
import CoreMedia
import AppKit

final class CaptureManager: NSObject {
    private var streams: [SCStream] = []
    private var outputs: [FrameOutput] = []
    private let outputQueue = DispatchQueue(label: "TimeScroll.Capture.Output")
    private let streamDelegate = StreamDelegate()
    private let onSnapshot: (URL) -> Void

    init(onSnapshot: @escaping (URL) -> Void) {
        self.onSnapshot = onSnapshot
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.current

        // Determine which displays to capture based on settings (background-safe via UserDefaults)
        let d = UserDefaults.standard
        let modeRaw = d.string(forKey: "settings.captureDisplayMode") ?? "first"
        let captureAll = (modeRaw == "all")
        let displays: [SCDisplay] = captureAll ? content.displays : (content.displays.first.map { [$0] } ?? [])
        guard !displays.isEmpty else { throw NSError(domain: "TS", code: -2) }

        // Capture scale is user-configurable; default 0.8
        let capScale = (d.object(forKey: "settings.captureScale") != nil) ? d.double(forKey: "settings.captureScale") : 0.8
        let scale = max(0.5, min(capScale, 1.0))

        // Configure and start a stream per display
        var newStreams: [SCStream] = []
        var newOutputs: [FrameOutput] = []
        for display in displays {
            let cfg = SCStreamConfiguration()
            cfg.queueDepth = 8
            // NV12 saves bandwidth; if you see issues in your stack, switch back to BGRA.
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            cfg.showsCursor = false
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10) // 10 fps cap

            // Downscale at the source to cut energy cost
            if #available(macOS 13.0, *) {
                let w = Int(Double(display.width) * scale)
                let h = Int(Double(display.height) * scale)
                cfg.width = max(640, w)
                cfg.height = max(360, h)
                cfg.scalesToFit = true
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: cfg, delegate: streamDelegate)
            let output = FrameOutput(onSnapshot: onSnapshot)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            newStreams.append(stream)
            newOutputs.append(output)
        }

        // Assign to properties so they are retained during start
        self.streams = newStreams
        self.outputs = newOutputs
        for s in self.streams {
            try await s.startCapture()
        }
    }

    func stop() async {
        for s in streams {
            try? await s.stopCapture()
        }
        streams.removeAll()
        outputs.removeAll()
    }
}

final class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        #if DEBUG
        print("SCStream stopped with error:", error)
        #endif
    }
}

final class FrameOutput: NSObject, SCStreamOutput {
    // Cadence gating
    private var lastEvaluatedPTS: CMTime = .invalid
    private var lastPersistedPTS: CMTime = .invalid
    private var evaluating = false

    // Adaptive interval
    private var currentInterval: CFTimeInterval = 0
    private var baseInterval: CFTimeInterval {
        let v = UserDefaults.standard.double(forKey: "settings.captureMinInterval")
        return CFTimeInterval(v > 0 ? v : 2.0)
    }
    private var maxInterval: CFTimeInterval {
        let v = UserDefaults.standard.double(forKey: "settings.adaptiveMaxInterval")
        return CFTimeInterval(v > 0 ? v : 30.0)
    }

    // Work infra
    private let workQueue = DispatchQueue(label: "TimeScroll.Capture.Work", qos: .utility)
    // Dedicated serial queue for OCR so it does not contend with encode path
    private let ocrQueue = DispatchQueue(label: "TimeScroll.OCR", qos: .utility)
    private let onSnapshot: (URL) -> Void
    private let encoder = ImageEncoder()
    private let hasher = ImageHasher()

    // Dedup/adaptive
    private var lastHash: UInt64?
    private var stableCount: Int = 0

    // Thermal governance
    private var lastThermalState: ProcessInfo.ThermalState = .nominal
    private var lastThermalAdjustAt: TimeInterval = 0

    init(onSnapshot: @escaping (URL) -> Void) {
        self.onSnapshot = onSnapshot
        super.init()
        self.currentInterval = baseInterval
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, let pixelBuffer = sb.imageBuffer else { return }

        // Lightweight thermal governance check (every ~1s)
        applyThermalGovernorIfNeeded()

        // Clamp currentInterval to reflect any preference changes immediately
        let bInt = baseInterval
        let mInt = maxInterval
        if currentInterval < bInt || currentInterval > mInt {
            currentInterval = min(mInt, max(bInt, currentInterval))
        }

        // Gate evaluation cadence by PTS
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if lastEvaluatedPTS.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastEvaluatedPTS))
            if delta < currentInterval { return }
        }
        if evaluating { return }

        // Privacy: skip capture if the frontmost app is blacklisted
        if let blacklist = UserDefaults.standard.array(forKey: "settings.blacklistBundleIds") as? [String], !blacklist.isEmpty {
            let info = AppActivityTracker.shared.current()
            if let bid = info.bundleId, blacklist.contains(bid) {
                lastEvaluatedPTS = pts
                return
            }
        }

        evaluating = true
        lastEvaluatedPTS = pts

        // Snapshot background-readable settings
        let defaults = UserDefaults.standard
        let fmtRaw = defaults.string(forKey: "settings.storageFormat") ?? "heic"
        let fmt = SettingsStore.StorageFormat(rawValue: fmtRaw) ?? .heic
        let maxEdge = (defaults.object(forKey: "settings.maxLongEdge") != nil) ? defaults.integer(forKey: "settings.maxLongEdge") : 1600
        let quality = (defaults.object(forKey: "settings.lossyQuality") != nil) ? defaults.double(forKey: "settings.lossyQuality") : 0.6
        let dedupEnabled = (defaults.object(forKey: "settings.dedupEnabled") != nil) ? defaults.bool(forKey: "settings.dedupEnabled") : true
        let thr = (defaults.object(forKey: "settings.dedupHammingThreshold") != nil) ? defaults.integer(forKey: "settings.dedupHammingThreshold") : 8
        let adaptive = (defaults.object(forKey: "settings.adaptiveSampling") != nil) ? defaults.bool(forKey: "settings.adaptiveSampling") : true

        // IMPORTANT: Compute hash directly from the pixel buffer (cheap, uses CI) before making any CGImage.
        var hashVal: UInt64 = 0
        if dedupEnabled {
            hashVal = self.hasher.hash64(pixelBuffer: pixelBuffer)
            if let prev = self.lastHash {
                let hamming = ImageHasher.hamming(prev, hashVal)
                if hamming <= thr {
                    if adaptive {
                        self.stableCount += 1
                        self.currentInterval = min(self.maxInterval, self.baseInterval * CFTimeInterval(pow(1.5, Double(self.stableCount))))
                    }
                    self.evaluating = false
                    return
                }
            }
        }

        // Retain the pixel buffer to safely use it across queues.
        let retainedPB = Unmanaged.passRetained(pixelBuffer)
        workQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.evaluating = false
            }

            // Persist directly from the pixel buffer to avoid CGImage creation
            let pb = retainedPB.takeUnretainedValue()
            do {
                let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
                var encodedOpt: EncodedImage?
                var encError: Error?
                autoreleasepool {
                    do {
                        encodedOpt = try self.encoder.encode(pixelBuffer: pb, format: fmt, maxLongEdge: maxEdge, quality: quality)
                    } catch {
                        encError = error
                    }
                }
                if let e = encError { throw e }
                guard let encoded = encodedOpt else { throw ImageEncoderError.destinationFailed }
                // App metadata from tracker (no main-thread hop)
                let info = AppActivityTracker.shared.current()
                let bid = info.bundleId
                let name = info.name

                let d = UserDefaults.standard
                let vaultOn = (d.object(forKey: "settings.vaultEnabled") != nil) ? d.bool(forKey: "settings.vaultEnabled") : false
                let allowWhileLocked = (d.object(forKey: "settings.captureWhileLocked") != nil) ? d.bool(forKey: "settings.captureWhileLocked") : true
                if vaultOn && !VaultManager.shared.isUnlocked {
                    // Locked path: encrypt snapshot to .tse and enqueue ingest record
                    if allowWhileLocked {
                        let encURL = try FileCrypter.shared.encryptSnapshot(encoded: encoded, timestampMs: tsMs)
                        // OCR on the retained pixel buffer to keep queue rich with text
                        let ocrResult = try self.runOCR(retainedPB.takeUnretainedValue())
                        try IngestQueue.shared.enqueue(
                            path: encURL,
                            startedAtMs: tsMs,
                            appBundleId: bid,
                            appName: name,
                            bytes: Int64(encoded.data.count),
                            width: encoded.width,
                            height: encoded.height,
                            format: encoded.format,
                            hash64: Int64(bitPattern: hashVal),
                            ocrText: ocrResult.text,
                            ocrBoxes: ocrResult.lines
                        )
                    }
                    // Do not update lastSnapshotURL to avoid revealing disk paths while locked
                    retainedPB.release()
                    return
                }

                // Normal path: if vault enabled (unlocked), write encrypted file; else plaintext
                let url: URL
                let bytes: Int64
                if vaultOn {
                    url = try FileCrypter.shared.encryptSnapshot(encoded: encoded, timestampMs: tsMs)
                    bytes = Int64(encoded.data.count)
                } else {
                    let ret = try SnapshotStore.shared.saveEncoded(encoded, timestampMs: tsMs, formatExt: encoded.format)
                    url = ret.url; bytes = ret.bytes
                }
                let rowId = Indexer.shared.insertStub(
                    startedAtMs: tsMs,
                    savedURL: url,
                    extra: Indexer.SnapshotExtraMeta(
                        bytes: bytes,
                        width: encoded.width,
                        height: encoded.height,
                        format: encoded.format,
                        hash64: Int64(bitPattern: hashVal)
                    ),
                    appBundleId: bid,
                    appName: name
                )

                // Notify UI before OCR to avoid races
                DispatchQueue.main.async { self.onSnapshot(url) }

                // Reset adaptive state after a real persist
                self.lastHash = hashVal
                self.stableCount = 0
                self.currentInterval = self.baseInterval
                self.lastPersistedPTS = pts

                // Offload OCR to a dedicated serial queue; retain/release around the async call.
                self.ocrQueue.async {
                    let pb2 = retainedPB.takeUnretainedValue()
                    Indexer.shared.completeOCR(snapshotId: rowId, pixelBuffer: pb2)
                    retainedPB.release()
                }
            } catch {
                retainedPB.release()
                // swallow for now
            }
        }
    }

    private func runOCR(_ pixelBuffer: CVPixelBuffer) throws -> OCRResult {
        // Keep a small OCR service per FrameOutput to avoid contention
        return try self.ocr().recognize(from: pixelBuffer)
    }

    private var _ocrService: OCRService?
    private func ocr() -> OCRService {
        if let s = _ocrService { return s }
        let s = OCRService(); _ocrService = s; return s
    }

    private func applyThermalGovernorIfNeeded() {
        let now = Date().timeIntervalSince1970
        if now - lastThermalAdjustAt < 1.0 { return } // check ~1Hz
        lastThermalAdjustAt = now

        let state = ProcessInfo.processInfo.thermalState
        guard state != lastThermalState else { return }

        switch state {
        case .nominal, .fair:
            // Return to normal; nothing to do (cooldown auto-expires in Indexer)
            break
        case .serious:
            currentInterval = min(maxInterval, max(currentInterval, baseInterval) * 2)
            Indexer.shared.setOCRCooldown(seconds: 30)
        case .critical:
            currentInterval = min(maxInterval, max(currentInterval, baseInterval) * 3)
            Indexer.shared.setOCRCooldown(seconds: 60)
        @unknown default:
            break
        }

        lastThermalState = state
    }
}
