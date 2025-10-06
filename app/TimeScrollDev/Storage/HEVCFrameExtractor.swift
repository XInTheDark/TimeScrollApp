import Foundation
import AVFoundation
import AppKit
import CoreImage

/// Utilities to extract still frames from HEVC segments.
enum HEVCFrameExtractor {
    // Reuse heavy objects
    static let ciContext = CIContext(options: nil)
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HH-mm-ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func image(forPath path: URL, startedAtMs: Int64, format: String, maxPixel: CGFloat? = nil) -> NSImage? {
        guard format.lowercased() == "hevc" else { return nil }
        let start = startFromSegmentURL(path) ?? startedAtMs
        let offset = max(0, startedAtMs - start)
        let ext = path.pathExtension.lowercased()
        if ext == "mov" {
            guard let cg = copyFrame(fromMOV: path, offsetMs: offset) else { return nil }
            return downsampleCG(cg, maxPixel: maxPixel)
        } else if ext == "tse" {
            // Prefer sealed .tse if decryptable; otherwise fall back to the live .mov in Videos/
            let live = StoragePaths.videosDir().appendingPathComponent("seg-\(formatStart(start)).mov")
            if FileManager.default.fileExists(atPath: path.path) {
                if let (header, data) = try? FileCrypter.shared.decryptTSE(at: path), header.mime.contains("video") {
                    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".mov")
                    do { try data.write(to: tmp) } catch { return nil }
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    if let cg = copyFrame(fromMOV: tmp, offsetMs: offset) { return downsampleCG(cg, maxPixel: maxPixel) }
                    // If the sealed path exists but we cannot decode a frame yet, try live file as a fallback.
                    if FileManager.default.fileExists(atPath: live.path), let cg = copyFrame(fromMOV: live, offsetMs: offset) { return downsampleCG(cg, maxPixel: maxPixel) }
                    return nil
                } else {
                    // Decrypt failed (vault locked, etc). Try live file if present.
                    if FileManager.default.fileExists(atPath: live.path), let cg = copyFrame(fromMOV: live, offsetMs: offset) { return downsampleCG(cg, maxPixel: maxPixel) }
                    return nil
                }
            } else {
                // No sealed file yet – use the live .mov.
                guard FileManager.default.fileExists(atPath: live.path), let cg = copyFrame(fromMOV: live, offsetMs: offset) else { return nil }
                return downsampleCG(cg, maxPixel: maxPixel)
            }
        }
        return nil
    }

    private static func copyFrame(fromMOV url: URL, offsetMs: Int64) -> CGImage? {
        let opts: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        let asset = AVURLAsset(url: url, options: opts)
        func tryWith(tBefore: CMTime, tAfter: CMTime, targetMs: Int64, extraNudges: [Int64] = []) -> CGImage? {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = tBefore
            gen.requestedTimeToleranceAfter  = tAfter
            let t = CMTime(value: CMTimeValue(max(0, targetMs)), timescale: 1000)
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) { return cg }
            for n in extraNudges {
                let tt = CMTime(value: CMTimeValue(max(0, targetMs + n)), timescale: 1000)
                if let cg = try? gen.copyCGImage(at: tt, actualTime: nil) { return cg }
            }
            return nil
        }
        // Clamp to duration
        var targetMs = offsetMs
        let dur = asset.duration
        if dur.isNumeric && dur.isValid {
            let durMs = Int64((CMTimeGetSeconds(dur) * 1000.0).rounded(.down))
            if durMs > 1 { targetMs = min(targetMs, durMs - 1) }
        }
        // Pass 1: exact
        if let cg = tryWith(tBefore: .zero, tAfter: .zero, targetMs: targetMs) { return cg }
        // Pass 2: nudge around (covers B-frame rounding and nearby flush)
        let nudges1: [Int64] = [-2000, -1000, -500, -200, -50, -30, -10, 10]
        if let cg = tryWith(tBefore: .zero, tAfter: .zero, targetMs: targetMs, extraNudges: nudges1) { return cg }
        // Pass 3: widen tolerance to accept nearest available sample up to 800ms earlier and 200ms after
        let before = CMTime(value: 800, timescale: 1000) // 0.8s
        let after  = CMTime(value: 200, timescale: 1000) // 0.2s
        if let cg = tryWith(tBefore: before, tAfter: after, targetMs: targetMs) { return cg }
        // Pass 4: step back in 100ms chunks up to 2s
        var step: Int64 = 100
        while step <= 2000 {
            if let cg = tryWith(tBefore: before, tAfter: after, targetMs: max(0, targetMs - step)) { return cg }
            step += 100
        }
        return nil
    }

    private static func startFromSegmentURL(_ url: URL) -> Int64? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("seg-") else { return nil }
        let ts = String(name.dropFirst(4))
        if let d = df.date(from: ts) { return Int64(d.timeIntervalSince1970 * 1000) }
        return nil
    }

    private static func formatStart(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms)/1000)
        return df.string(from: d)
    }
}

// High-quality, background-safe downsample using Core Image Lanczos; avoids AppKit drawing off-main.
private func downsampleCG(_ cg: CGImage, maxPixel: CGFloat?) -> NSImage {
    guard let limit = maxPixel else { return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let maxEdge = max(w, h)
    if maxEdge <= limit {
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    let scale = limit / maxEdge
    let outW = Int((w * scale).rounded())
    let outH = Int((h * scale).rounded())
    let ci = CIImage(cgImage: cg)
    let filter = CIFilter(name: "CILanczosScaleTransform")!
    filter.setValue(ci, forKey: kCIInputImageKey)
    filter.setValue(scale, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    let ctx = HEVCFrameExtractor.ciContext
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let outCI = filter.outputImage,
          let outCG = ctx.createCGImage(outCI, from: CGRect(x: 0, y: 0, width: outW, height: outH), format: CIFormat.RGBA8, colorSpace: colorSpace) else {
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    return NSImage(cgImage: outCG, size: NSSize(width: outW, height: outH))
}
