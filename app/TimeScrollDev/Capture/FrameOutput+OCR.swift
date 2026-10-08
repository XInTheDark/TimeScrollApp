import Foundation
import CoreVideo

extension FrameOutput {
    func processText(snapshotId: Int64, retainedPixelBuffer: Unmanaged<CVPixelBuffer>) {
        // Keep capture admission occupied until text processing releases this buffer.
        ocrQueue.sync { [weak self] in
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
                SnapshotEmbeddingQueue.shared.enqueue(snapshotId: snapshotId, pixelBuffer: pixelBuffer, extractedText: nil)
                break
            }
            retainedPixelBuffer.release()
        }
    }

    func handleAccessibilityText(snapshotId: Int64, pixelBuffer: CVPixelBuffer) {
        let blacklist = UserDefaults.standard.array(forKey: "settings.blacklistBundleIds") as? [String] ?? []
        let capture = AXTextExtractor.shared.collect(blacklistBundleIds: Set(blacklist), displayBounds: displayBounds)
        let text = capture.text
        let fingerprint = TextFingerprint.make(from: text)
        let lines = Self.normalizedLines(text)

        // Near-duplicate text (vs. the last anchor) is stored in full but only its new lines are
        // indexed: search still finds every line, while text that stays on screen matches the
        // anchor instead of every following snapshot.
        var indexedContent: String?
        if let anchor = lastTextAnchor, fingerprint.isNearDuplicate(of: anchor.fingerprint) {
            indexedContent = lines.filter { !anchor.lines.contains($0) }.joined(separator: "\n")
            if UserDefaults.standard.bool(forKey: "settings.debugMode") {
                print("[Capture] Near-duplicate text, hamming=\(fingerprint.hammingDistance(to: anchor.fingerprint)), anchor=\(anchor.id)")
            }
        } else {
            lastTextAnchor = (snapshotId, fingerprint, Set(lines))
        }
        do {
            try DB.shared.updateFTS(rowId: snapshotId, content: text, indexedContent: indexedContent)
            if !capture.lines.isEmpty {
                try DB.shared.replaceBoxes(snapshotId: snapshotId, boxes: capture.lines)
            }
        } catch {
            // Swallow errors; debug log if needed
        }
        SnapshotEmbeddingQueue.shared.enqueue(snapshotId: snapshotId, pixelBuffer: pixelBuffer, extractedText: text)
    }

    static func normalizedLines(_ text: String) -> [String] {
        var lines: [String] = []
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines
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
