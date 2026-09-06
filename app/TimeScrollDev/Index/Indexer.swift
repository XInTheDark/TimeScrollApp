import Foundation
import CoreVideo
import AppKit

final class Indexer {
    static let shared = Indexer()
    private init() {}

    private let ocr = OCRService()
    private let ocrQueue = DispatchQueue(label: "TimeScroll.Indexer.OCR", qos: .utility)
    private var ocrCooldownUntil: TimeInterval = 0
    private let cooldownLock = NSLock()

    var isOCRCoolingDown: Bool {
        cooldownLock.lock()
        defer { cooldownLock.unlock() }
        return Date().timeIntervalSince1970 < ocrCooldownUntil
    }

    struct SnapshotExtraMeta {
        let bytes: Int64
        let width: Int
        let height: Int
        let format: String
        let hash64: Int64
    }

    func setOCRCooldown(seconds: Double) {
        guard seconds > 0 else { return }
        cooldownLock.lock()
        defer { cooldownLock.unlock() }
        let until = Date().timeIntervalSince1970 + seconds
        ocrCooldownUntil = max(ocrCooldownUntil, until)
    }

    @discardableResult
    func insertStub(startedAtMs: Int64, savedURL: URL, extra: SnapshotExtraMeta, appBundleId: String?, appName: String?, thumbPath: String? = nil, textRefId: Int64? = nil) throws -> Int64 {
        try DB.shared.insertSnapshot(
            startedAtMs: startedAtMs,
            path: savedURL.path,
            text: "",
            appBundleId: appBundleId,
            appName: appName,
            boxes: [],
            bytes: extra.bytes,
            width: extra.width,
            height: extra.height,
            format: extra.format,
            hash64: extra.hash64,
            thumbPath: thumbPath,
            textRefId: textRefId
        )
    }

    func completeOCR(snapshotId: Int64, pixelBuffer: CVPixelBuffer) {
        guard snapshotId > 0 else { return }
        ocrQueue.sync {
            // Admission pauses during cooldown. Finish already-saved captures instead
            // of retaining their stream-pool buffers in a deferred queue.
            performOCR(snapshotId: snapshotId, pixelBuffer: pixelBuffer)
        }
    }

    private func performOCR(snapshotId: Int64, pixelBuffer: CVPixelBuffer) {
        do {
            let result = try ocr.recognize(from: pixelBuffer)
            try DB.shared.updateFTS(rowId: snapshotId, content: result.text)
            if !result.lines.isEmpty {
                try DB.shared.replaceBoxes(snapshotId: snapshotId, boxes: result.lines)
            }
            SnapshotEmbeddingWriter.shared.storeCurrentEmbeddingIfNeeded(snapshotId: snapshotId, pixelBuffer: pixelBuffer, extractedText: result.text)
        } catch {
        }
    }

    // Legacy index(path) consolidated into stub + OCR path

    func rebuildFTSFromFiles() {
        let dir = SnapshotStore.shared.snapshotsDir
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return }
        while let obj = enumerator.nextObject() as? URL {
            let ext = obj.pathExtension.lowercased()
            guard ["png","jpg","jpeg","heic"].contains(ext) else { continue }
            guard let vals = try? obj.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), vals.isRegularFile == true else { continue }
            let ms = Int64((vals.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            let bytes = Int64(vals.fileSize ?? 0)
            var w = 0, h = 0
            if let src = CGImageSourceCreateWithURL(obj as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] {
                w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
                h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            }
            let fmt = (ext == "jpeg") ? "jpg" : ext
            _ = try? DB.shared.insertSnapshot(
                startedAtMs: ms,
                path: obj.path,
                text: "",
                appBundleId: nil,
                appName: nil,
                boxes: [],
                bytes: bytes,
                width: w,
                height: h,
                format: fmt,
                hash64: nil,
                thumbPath: nil
            )
        }
    }
}
