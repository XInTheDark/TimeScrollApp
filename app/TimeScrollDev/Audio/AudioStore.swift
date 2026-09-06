import Foundation
import AVFoundation

enum AudioStore {
    private static let transcriptionTempPrefix = "timescroll-audio-transcription-"

    static func makeStagingURL(sourceKind: AudioSourceKind, fileExtension: String = "m4a") -> URL {
        StoragePaths.withSecurityScope {
            let directory = stagingDirectory()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let filename = "\(sourceKind.rawValue)-\(UUID().uuidString).\(fileExtension)"
            return directory.appendingPathComponent(filename)
        }
    }

    static func finalizeRecordedSegment(at sourceURL: URL,
                                        startedAtMs: Int64,
                                        sourceKind: AudioSourceKind,
                                        mime: String) throws -> (url: URL, bytes: Int64) {
        try StoragePaths.withSecurityScope {
            let finalURL = try uniqueFinalURL(startedAtMs: startedAtMs,
                                              sourceKind: sourceKind,
                                              originalExtension: sourceURL.pathExtension)
            let fm = FileManager.default
            let vaultEnabled = UserDefaults.standard.bool(forKey: "settings.vaultEnabled")

            if vaultEnabled {
                let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                let blob = try FileCrypter.shared.makeTSEBlob(data: data,
                                                              timestampMs: startedAtMs,
                                                              width: 0,
                                                              height: 0,
                                                              mime: mime)
                let encryptedURL = finalURL.deletingPathExtension().appendingPathExtension("tse")
                let tmpURL = encryptedURL.appendingPathExtension("tmp")
                try blob.write(to: tmpURL, options: .atomic)
                if fm.fileExists(atPath: encryptedURL.path) {
                    let _ = try fm.replaceItemAt(encryptedURL, withItemAt: tmpURL)
                } else {
                    try fm.moveItem(at: tmpURL, to: encryptedURL)
                }
                try? fm.removeItem(at: sourceURL)
                let size = (try? encryptedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? Int64(blob.count)
                return (encryptedURL, size)
            }

            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: sourceURL, to: finalURL)
            let size = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return (finalURL, size)
        }
    }

    static func transcriptionInputURL(for storedURL: URL) throws -> URL {
        guard storedURL.pathExtension.lowercased() == "tse" else { return storedURL }
        let (_, data) = try FileCrypter.shared.decryptTSE(at: storedURL)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(transcriptionTempPrefix)\(UUID().uuidString).m4a")
        try data.write(to: temporaryURL, options: .atomic)
        return temporaryURL
    }

    static func removeTranscriptionInputIfTemporary(_ url: URL) {
        guard url.deletingLastPathComponent() == FileManager.default.temporaryDirectory,
              url.lastPathComponent.hasPrefix(transcriptionTempPrefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupAbandonedTranscriptionInputs() {
        let directory = FileManager.default.temporaryDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(transcriptionTempPrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func abandonedRecordedSegments() -> [RecordedAudioSegment] {
        let directory = stagingDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard ["m4a", "caf"].contains(url.pathExtension.lowercased()) else { return nil }
            guard let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let startDate = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let startedAtMs = Int64(startDate.timeIntervalSince1970 * 1000)
            let endedAtMs = startedAtMs + Int64((player.duration * 1000).rounded())
            let sourceKind: AudioSourceKind = url.lastPathComponent.hasPrefix("system-") ? .system : .microphone
            return RecordedAudioSegment(sourceKind: sourceKind,
                                        sourceDisplayName: sourceKind.displayName,
                                        tempURL: url,
                                        startedAtMs: startedAtMs,
                                        endedAtMs: endedAtMs,
                                        mime: "audio/mp4",
                                        sampleRate: nil,
                                        channels: nil)
        }
    }

    private static func stagingDirectory() -> URL {
        StoragePaths.audioDir().appendingPathComponent("Staging", isDirectory: true)
    }

    private static func uniqueFinalURL(startedAtMs: Int64,
                                       sourceKind: AudioSourceKind,
                                       originalExtension: String) throws -> URL {
        let day = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000)
        let folder = StoragePaths.audioDir().appendingPathComponent(Self.dayFormatter.string(from: day), isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let ext = originalExtension.isEmpty ? "m4a" : originalExtension
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let url = folder.appendingPathComponent("audio-\(sourceKind.rawValue)-\(startedAtMs)\(suffix).\(ext)")
            if !fm.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
