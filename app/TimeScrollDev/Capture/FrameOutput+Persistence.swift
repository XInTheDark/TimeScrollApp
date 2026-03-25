import Foundation
import CoreVideo

extension FrameOutput {
    func extractTextForSnapshot(pixelBuffer: CVPixelBuffer,
                                startedAtMs: Int64,
                                processing: SettingsStore.TextProcessingMode,
                                blacklistBundleIds: [String]) -> (text: String, boxes: [OCRLine]) {
        switch processing {
        case .ocr:
            // Existing OCR path
            if let result = try? runOCR(pixelBuffer) {
                return (result.text, result.lines)
            }
            return ("", [])
        case .accessibility:
            let set = Set(blacklistBundleIds)
            let text = AXTextExtractor.shared.collectText(blacklistBundleIds: set)
            return (text, [])
        case .none:
            return ("", [])
        }
    }

    func persist(
        pixelBuffer: CVPixelBuffer,
        fmt: SettingsStore.StorageFormat,
        tsMs: Int64,
        maxEdge: Int,
        quality: Double,
        vaultOn: Bool,
        allowWhileLocked: Bool,
        hash64: UInt64,
        appBundleId: String?,
        appName: String?
    ) throws -> PersistOutcome {
        let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")
        switch fmt {
        case .hevc:
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            if vaultOn && !unlocked {
                guard allowWhileLocked else { return .skippedWhileLocked }
                HEVCVideoStore.shared.append(pixelBuffer: pixelBuffer, timestampMs: tsMs, encrypt: true)
                let targetURL = HEVCVideoStore.shared.urlFor(timestampMs: tsMs, encrypt: true)
                let bytes = (try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                let procRaw = UserDefaults.standard.string(forKey: "settings.textProcessingMode") ?? SettingsStore.defaultTextProcessingMode.rawValue
                let proc = SettingsStore.TextProcessingMode(rawValue: procRaw) ?? SettingsStore.defaultTextProcessingMode
                let blacklist = UserDefaults.standard.array(forKey: "settings.blacklistBundleIds") as? [String] ?? []
                let extracted = extractTextForSnapshot(pixelBuffer: pixelBuffer,
                                                       startedAtMs: tsMs,
                                                       processing: proc,
                                                       blacklistBundleIds: blacklist)
                let thumb = makePosterThumbIfPossible(pixelBuffer: pixelBuffer, tsMs: tsMs, maxEdge: maxEdge, quality: quality, encrypt: true)
                try IngestQueue.shared.enqueue(
                    path: targetURL,
                    startedAtMs: tsMs,
                    appBundleId: appBundleId,
                    appName: appName,
                    bytes: bytes,
                    width: width,
                    height: height,
                    format: "hevc",
                    hash64: Int64(bitPattern: hash64),
                    ocrText: extracted.text,
                    ocrBoxes: extracted.boxes,
                    thumbPath: thumb
                )
                return .queuedWhileLocked
            } else {
                HEVCVideoStore.shared.append(pixelBuffer: pixelBuffer, timestampMs: tsMs, encrypt: vaultOn)
                let url = HEVCVideoStore.shared.urlFor(timestampMs: tsMs, encrypt: vaultOn)
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                let thumb = makePosterThumbIfPossible(pixelBuffer: pixelBuffer, tsMs: tsMs, maxEdge: maxEdge, quality: quality, encrypt: vaultOn)
                return .saved(url: url, bytes: bytes, width: width, height: height, thumbPath: thumb)
            }

        case .heic, .jpeg, .png:
            let encoded = try encoder.encode(pixelBuffer: pixelBuffer, format: fmt, maxLongEdge: maxEdge, quality: quality)

            if vaultOn && !unlocked {
                guard allowWhileLocked else { return .skippedWhileLocked }
                let encURL = try FileCrypter.shared.encryptSnapshot(encoded: encoded, timestampMs: tsMs)
                let procRaw = UserDefaults.standard.string(forKey: "settings.textProcessingMode") ?? SettingsStore.defaultTextProcessingMode.rawValue
                let proc = SettingsStore.TextProcessingMode(rawValue: procRaw) ?? SettingsStore.defaultTextProcessingMode
                let blacklist = UserDefaults.standard.array(forKey: "settings.blacklistBundleIds") as? [String] ?? []
                let extracted = extractTextForSnapshot(pixelBuffer: pixelBuffer,
                                                       startedAtMs: tsMs,
                                                       processing: proc,
                                                       blacklistBundleIds: blacklist)
                try IngestQueue.shared.enqueue(
                    path: encURL,
                    startedAtMs: tsMs,
                    appBundleId: appBundleId,
                    appName: appName,
                    bytes: Int64(encoded.data.count),
                    width: encoded.width,
                    height: encoded.height,
                    format: encoded.format,
                    hash64: Int64(bitPattern: hash64),
                    ocrText: extracted.text,
                    ocrBoxes: extracted.boxes,
                    thumbPath: nil
                )
                return .queuedWhileLocked
            } else if vaultOn {
                let url = try FileCrypter.shared.encryptSnapshot(encoded: encoded, timestampMs: tsMs)
                return .saved(url: url, bytes: Int64(encoded.data.count), width: encoded.width, height: encoded.height, thumbPath: nil)
            } else {
                let ret = try SnapshotStore.shared.saveEncoded(encoded, timestampMs: tsMs, formatExt: encoded.format)
                return .saved(url: ret.url, bytes: ret.bytes, width: encoded.width, height: encoded.height, thumbPath: nil)
            }
        }
    }

    func makePosterThumbIfPossible(
        pixelBuffer: CVPixelBuffer,
        tsMs: Int64,
        maxEdge: Int,
        quality: Double,
        encrypt: Bool
    ) -> String? {
        // Skip poster work during thermal backoff window
        if Date().timeIntervalSince1970 < suppressPostersUntil { return nil }
        do {
            let poster = try encoder.encode(pixelBuffer: pixelBuffer, format: .heic, maxLongEdge: maxEdge, quality: quality)
            if encrypt {
                let encURL = try FileCrypter.shared.encryptSnapshot(encoded: poster, timestampMs: tsMs)
                return encURL.path
            } else {
                let saved = try SnapshotStore.shared.saveEncoded(poster, timestampMs: tsMs, formatExt: poster.format)
                return saved.url.path
            }
        } catch {
            return nil
        }
    }
}
