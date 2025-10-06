import Foundation
import AVFoundation
import VideoToolbox
import CoreImage
import CoreVideo
#if canImport(Collections)
import Collections
#endif
import CoreGraphics

final class HEVCVideoStore {
    static let shared = HEVCVideoStore(); private init() {}

    // Config
    private let segmentMs: Int64 = 60_000
    private let targetBitrate: Int = 700_000
    private let fps: Int32 = 5

    // State
    private let queue = DispatchQueue(label: "TimeScroll.HEVCVideoStore")
    private let ciContext = CIContext(options: nil)
    private var current: Active?
    #if canImport(Collections)
    private var pendingFrames = Deque<QueuedFrame>()
    #else
    private var pendingFrames = FrameDeque()
    #endif
    private var draining: Bool = false
    private var awaitingCallback: Bool = false

    private struct Active {
        let startMs: Int64
        let encrypt: Bool
        let width: Int
        let height: Int
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var started: Bool
        let outURL: URL // .mov
    }

    private struct QueuedFrame { let pb: CVPixelBuffer; let pts: CMTime }

    // Simple deque optimized for O(1) pops without repeated copying
    private struct FrameDeque {
        private var buf: [QueuedFrame?] = []
        private var head: Int = 0
        var isEmpty: Bool { head >= buf.count }
        mutating func append(_ f: QueuedFrame) { buf.append(f) }
        mutating func popFirst() -> QueuedFrame? {
            guard head < buf.count else { return nil }
            let v = buf[head]
            buf[head] = nil
            head &+= 1
            // Occasionally compact to keep memory bounded
            if head > 64 && head * 2 >= buf.count {
                buf.removeFirst(head)
                head = 0
            }
            return v
        }
        mutating func removeAll() { buf.removeAll(keepingCapacity: true); head = 0 }
    }

    // Public API
    func append(pixelBuffer: CVPixelBuffer, timestampMs: Int64, encrypt: Bool) {
        queue.async {
            autoreleasepool { try? self._append(pixelBuffer: pixelBuffer, ts: timestampMs, encrypt: encrypt) }
        }
    }

    func urlFor(timestampMs: Int64, encrypt: Bool) -> URL {
        let start = alignedStart(timestampMs)
        return encrypt ? finalEncURL(forStart: start) : plainURL(forStart: start)
    }

    func shutdown(timeout: TimeInterval = 2.0) {
        let sema = DispatchSemaphore(value: 0)
        queue.async { try? self.closeCurrent(); sema.signal() }
        _ = sema.wait(timeout: .now() + timeout)
    }

    // Core
    private func _append(pixelBuffer: CVPixelBuffer, ts: Int64, encrypt: Bool) throws {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let start = alignedStart(ts)
        if needsRollover(start: start, encrypt: encrypt, width: w, height: h) {
            try closeCurrent(); current = try open(startMs: start, width: w, height: h, encrypt: encrypt)
        }
        guard var c = current else { return }
        if !c.started { _ = c.writer.startWriting(); c.writer.startSession(atSourceTime: .zero); c.started = true }
        let want = c.adaptor.sourcePixelBufferAttributes?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType ?? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let pts = CMTime(value: CMTimeValue(max(0, ts - c.startMs)), timescale: 1000)
        if fmt == want {
            enqueueFrame(pixelBuffer, pts: pts)
        } else {
            var out: CVPixelBuffer?
            guard let pool = c.adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb),
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                let ci = CIImage(cvPixelBuffer: pixelBuffer)
                if let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) {
                    ctx.interpolationQuality = .none
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            enqueueFrame(pb, pts: pts)
        }
        if ts >= c.startMs + segmentMs - 1 { try closeCurrent() } else { current = c }
    }

    private func needsRollover(start: Int64, encrypt: Bool, width: Int, height: Int) -> Bool {
        guard let c = current else { return true }
        return c.startMs != start || c.encrypt != encrypt || c.width != width || c.height != height
    }

    private func open(startMs: Int64, width: Int, height: Int, encrypt: Bool) throws -> Active {
        let fm = FileManager.default
        let outURL: URL
        let videos = StoragePaths.videosDir()
        if !fm.fileExists(atPath: videos.path) { try? fm.createDirectory(at: videos, withIntermediateDirectories: true) }
        //  always write the live, open segment as Videos/seg-*.mov.
        // When encryption is enabled, we will encrypt-and-replace on close().
        outURL = videos.appendingPathComponent("seg-\(segmentName(startMs)).mov")
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        // Enable progressive readability of in‑progress files and place moov up front
        writer.shouldOptimizeForNetworkUse = true
        // Short fragment interval improves live readability at the cost of a few more moofs
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            AVVideoAllowFrameReorderingKey: false, // reduce latency/complexity
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 10,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if input.responds(to: Selector(("setPerformsMultiPassEncodingIfSupported:"))) {
            input.performsMultiPassEncodingIfSupported = false
        }
        writer.add(input)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        // Start writing immediately so the container header is present as soon as the
        // segment opens. This allows AVAsset readers to access frames while recording.
        _ = writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        // Do not register a perpetual readiness callback here; we'll request callbacks
        // only when frames are pending and the input is back-pressured.
        return Active(startMs: startMs, encrypt: encrypt, width: width, height: height, writer: writer, input: input, adaptor: adaptor, started: true, outURL: outURL)
    }

    private func closeCurrent() throws {
        guard let c = current else { return }
        // Stop accepting new frames and finish
        c.input.markAsFinished()
        clearPendingFrames()
        let g = DispatchGroup(); g.enter(); c.writer.finishWriting { g.leave() }; g.wait()
        if c.encrypt {
            if let data = try? Data(contentsOf: c.outURL, options: [.mappedIfSafe]), let blob = try? FileCrypter.shared.makeTSEBlob(data: data, timestampMs: c.startMs, width: c.width, height: c.height, mime: "video/quicktime") {
                let dest = finalEncURL(forStart: c.startMs); let tmp = dest.appendingPathExtension("tmp")
                try? blob.write(to: tmp, options: .atomic); let _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            }
            _ = try? FileManager.default.removeItem(at: c.outURL)
        }
        else {
        }
        // After a segment is sealed/closed, remove posters for rows in this segment window.
        PosterManager.cleanupSegment(startMs: c.startMs, endMs: c.startMs + segmentMs - 1)
        awaitingCallback = false
        current = nil
    }

    // MARK: - Queue/Drain
    private func enqueueFrame(_ pb: CVPixelBuffer, pts: CMTime) {
        // Enqueue the pixel buffer; ARC keeps it alive until popped
        pendingFrames.append(QueuedFrame(pb: pb, pts: pts))
        drainIfPossible()
    }

    private func drainIfPossible() {
        guard let c = current else { return }
        drainPending(for: c.input, adaptor: c.adaptor)
    }

    private func drainPending(for input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        if draining { return }
        if pendingFrames.isEmpty { return }
        draining = true
        while input.isReadyForMoreMediaData, let f = pendingFrames.popFirst() {
            _ = adaptor.append(f.pb, withPresentationTime: f.pts)
        }
        draining = false
        if !pendingFrames.isEmpty { scheduleCallbackIfNeeded(for: input, adaptor: adaptor) }
    }

    private func clearPendingFrames() {
        pendingFrames.removeAll()
    }

    private func scheduleCallbackIfNeeded(for input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        if awaitingCallback { return }
        awaitingCallback = true
        input.requestMediaDataWhenReady(on: queue) { [weak self, weak input] in
            guard let self = self, let input = input else { return }
            self.awaitingCallback = false
            self.drainPending(for: input, adaptor: adaptor)
        }
    }

    // Paths
    private func alignedStart(_ t: Int64) -> Int64 { (t / segmentMs) * segmentMs }
    private func segmentName(_ ms: Int64) -> String { HEVCVideoStore.segmentName(ms) }
    private func plainURL(forStart s: Int64) -> URL { StoragePaths.videosDir().appendingPathComponent("seg-\(segmentName(s)).mov") }
    private func finalEncURL(forStart s: Int64) -> URL { StoragePaths.videosDir().appendingPathComponent("seg-\(segmentName(s)).tse") }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HH-mm-ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static func segmentName(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms)/1000)
        return df.string(from: d)
    }
}
