import Foundation
import CoreVideo

extension FrameOutput {
    func processText(snapshotId: Int64, retainedPixelBuffer: Unmanaged<CVPixelBuffer>) {
        ocrQueue.async { [weak self] in
            guard let self else {
                retainedPixelBuffer.release()
                return
            }

            let pixelBuffer = retainedPixelBuffer.takeUnretainedValue()
            let modeRaw = UserDefaults.standard.string(forKey: "settings.textProcessingMode") ?? SettingsStore.defaultTextProcessingMode.rawValue
            let mode = SettingsStore.TextProcessingMode(rawValue: modeRaw) ?? SettingsStore.defaultTextProcessingMode
            switch mode {
            case .ocr:
                Indexer.shared.completeOCR(snapshotId: snapshotId, pixelBuffer: pixelBuffer)
            case .accessibility:
                handleAccessibilityText(snapshotId: snapshotId, pixelBuffer: pixelBuffer)
            case .none:
                SnapshotEmbeddingWriter.shared.storeCurrentEmbeddingIfNeeded(snapshotId: snapshotId, pixelBuffer: pixelBuffer, extractedText: nil)
                break
            }
            retainedPixelBuffer.release()
        }
    }

    func handleAccessibilityText(snapshotId: Int64, pixelBuffer: CVPixelBuffer) {
        let blacklist = UserDefaults.standard.array(forKey: "settings.blacklistBundleIds") as? [String] ?? []
        let text = AXTextExtractor.shared.collectText(blacklistBundleIds: Set(blacklist))
        let fingerprint = TextFingerprint.make(from: text)

        // Dedup check
        var isDuplicate = false
        if let last = lastCapturedFingerprint {
            let distance = fingerprint.hammingDistance(to: last.fingerprint)
            if fingerprint.isNearDuplicate(of: last.fingerprint) {
                if UserDefaults.standard.bool(forKey: "settings.debugMode") {
                    print("[Capture] Deduplicating text, hamming=\(distance), refId=\(last.id)")
                }
                // Store reference to the ANCHOR snapshot
                try? DB.shared.updateSnapshotTextRef(rowId: snapshotId, refId: last.id)
                isDuplicate = true
            }
        }

        if !isDuplicate {
            // This is a new anchor
            lastCapturedFingerprint = (snapshotId, fingerprint)
            do {
                try DB.shared.updateFTS(rowId: snapshotId, content: text)
            } catch {
                // Swallow errors; debug log if needed
            }
        }
        SnapshotEmbeddingWriter.shared.storeCurrentEmbeddingIfNeeded(snapshotId: snapshotId, pixelBuffer: pixelBuffer, extractedText: text)
    }

    func runOCR(_ pixelBuffer: CVPixelBuffer) throws -> OCRResult {
        // Keep a small OCR service per FrameOutput to avoid contention
        try ocr().recognize(from: pixelBuffer)
    }

    func ocr() -> OCRService {
        if let service = ocrService { return service }
        let service = OCRService()
        ocrService = service
        return service
    }
}
