import Foundation
import CoreVideo
import AppKit

final class Indexer {
    static let shared = Indexer()
    private init() {}

    private let ocr = OCRService()

    struct SnapshotExtraMeta {
        let bytes: Int64
        let width: Int
        let height: Int
        let format: String
        let hash64: Int64
    }

    // Thermal cooldown window for OCR (no baseline throttle)
    private let cooldownQueue = DispatchQueue(label: "TimeScroll.OCRCooldown")
    private var ocrCooldownUntil: TimeInterval = 0

    func setOCRCooldown(seconds: Double) {
        guard seconds > 0 else { return }
        cooldownQueue.sync {
            let until = Date().timeIntervalSince1970 + seconds
            ocrCooldownUntil = max(ocrCooldownUntil, until) // extend but never shorten
        }
    }

    @discardableResult
    func insertStub(startedAtMs: Int64, savedURL: URL, extra: SnapshotExtraMeta, appBundleId: String?, appName: String?) -> Int64 {
        let id = (try? DB.shared.insertSnapshot(
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
            thumbPath: nil
        )) ?? 0
        return id
    }

    func completeOCR(snapshotId: Int64, pixelBuffer: CVPixelBuffer) {
        // Respect thermal cooldown only
        var blocked = false
        cooldownQueue.sync {
            blocked = Date().timeIntervalSince1970 < ocrCooldownUntil
        }
        guard !blocked else { return }

        do {
            let result = try ocr.recognize(from: pixelBuffer)
            try DB.shared.updateFTS(rowId: snapshotId, content: result.text)
            if !result.lines.isEmpty {
                try DB.shared.replaceBoxes(snapshotId: snapshotId, boxes: result.lines)
            }
            // Optional: compute and store embedding of OCR text when enabled
            let d = UserDefaults.standard
            let aiOn = (d.object(forKey: "settings.aiEmbeddingsEnabled") != nil) ? d.bool(forKey: "settings.aiEmbeddingsEnabled") : false
            if aiOn {
                let svc = EmbeddingService.shared
                let (vec, known, total) = svc.embedWithStats(result.text)
                if !vec.isEmpty && svc.dim == vec.count {
                    try? DB.shared.upsertEmbedding(snapshotId: snapshotId, dim: svc.dim, vec: vec)
                    // Debug log snapshot embedding
                    if UserDefaults.standard.bool(forKey: "settings.debugMode") {
                        let head = vec.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                        print("[AI][Store] snapshotId=\(snapshotId) dim=\(vec.count) tokens=\(known)/\(total) head=[\(head)]")
                    }
                }
            }
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
