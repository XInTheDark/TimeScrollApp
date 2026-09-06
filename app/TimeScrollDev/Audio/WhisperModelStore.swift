import Foundation
import WhisperKit

extension Notification.Name {
    static let whisperModelAvailabilityDidChange = Notification.Name("TimeScroll.WhisperModelAvailabilityDidChange")
}

enum WhisperModelStore {
    private static let requiredModelArtifacts = [
        "MelSpectrogram",
        "AudioEncoder",
        "TextDecoder",
    ]

    static func modelsBaseURL() -> URL {
        let base = StoragePaths.sharedSupportRoot().appendingPathComponent("WhisperKitModels", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static func isModelAvailable(_ modelID: String) -> Bool {
        guard let modelDirectory = resolvedModelDirectory(for: modelID) else { return false }
        return isReady(modelDirectory: modelDirectory,
                       tokenizerDirectories: tokenizerSearchDirectories(for: modelID))
    }

    static func resolvedModelDirectory(for modelID: String) -> URL? {
        let installedDirectory = installedModelDirectory(for: modelID)
        return isCompleteModelDirectory(installedDirectory) ? installedDirectory : nil
    }

    @discardableResult
    static func download(modelID: String, progress: ((Progress) -> Void)? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: modelsBaseURL(), withIntermediateDirectories: true)
        // Keep model downloads in the app's foreground session.
        // WhisperKit's underlying Hub downloader wires progress and completion through
        // streaming tasks; opting into a background session here can leave the in-app
        // Settings flow stuck showing "Downloading…" without reliable completion callbacks.
        let modelDirectory = try await WhisperKit.download(variant: modelID,
                                                           downloadBase: modelsBaseURL(),
                                                           useBackgroundSession: false,
                                                           progressCallback: progress)
        let config = WhisperKitConfig(model: modelID,
                                      downloadBase: modelsBaseURL(),
                                      modelFolder: modelDirectory.path,
                                      tokenizerFolder: modelsBaseURL(),
                                      verbose: false,
                                      prewarm: false,
                                      download: false,
                                      useBackgroundDownloadSession: false)
        _ = try await WhisperKit(config)
        guard resolvedTokenizerDirectory(for: modelID) != nil else {
            throw NSError(domain: "TimeScroll.Audio",
                          code: -61,
                          userInfo: [NSLocalizedDescriptionKey: "The Whisper tokenizer did not finish downloading."])
        }
        NotificationCenter.default.post(name: .whisperModelAvailabilityDidChange, object: modelID)
        return modelDirectory
    }

    static func remove(modelID: String) throws {
        let directories = [
            cachedDownloadDirectory(for: modelID),
            installedModelDirectory(for: modelID),
            tokenizerDirectory(for: modelID),
        ]
        for url in directories where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        NotificationCenter.default.post(name: .whisperModelAvailabilityDidChange, object: modelID)
    }

    @discardableResult
    static func cleanupInterruptedDownload(modelID: String) throws -> Bool {
        var removedAny = false
        let cacheDirectory = cachedDownloadDirectory(for: modelID)
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
            removedAny = true
        }

        let installedDirectory = installedModelDirectory(for: modelID)
        if FileManager.default.fileExists(atPath: installedDirectory.path),
           !isCompleteModelDirectory(installedDirectory) {
            try FileManager.default.removeItem(at: installedDirectory)
            removedAny = true
        }
        return removedAny
    }

    private static func modelRepositoryRoot() -> URL {
        modelsBaseURL()
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    private static func installedModelDirectory(for modelID: String) -> URL {
        modelRepositoryRoot().appendingPathComponent(modelDirectoryName(for: modelID), isDirectory: true)
    }

    private static func cachedDownloadDirectory(for modelID: String) -> URL {
        modelRepositoryRoot()
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent(modelDirectoryName(for: modelID), isDirectory: true)
    }

    static func resolvedTokenizerDirectory(for modelID: String) -> URL? {
        tokenizerSearchDirectories(for: modelID).first { directory in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
        }
    }

    static func isReady(modelDirectory: URL, tokenizerDirectories: [URL]) -> Bool {
        isCompleteModelDirectory(modelDirectory)
            && tokenizerDirectories.contains { directory in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
            }
    }

    private static func tokenizerSearchDirectories(for modelID: String) -> [URL] {
        [
            tokenizerDirectory(for: modelID),
            installedModelDirectory(for: modelID),
            modelsBaseURL(),
        ]
    }

    private static func tokenizerDirectory(for modelID: String) -> URL {
        modelsBaseURL()
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("openai", isDirectory: true)
            .appendingPathComponent("whisper-\(modelID)", isDirectory: true)
    }

    private static func modelDirectoryName(for modelID: String) -> String {
        if modelID.hasPrefix("openai_whisper-") {
            return modelID
        }
        return "openai_whisper-\(modelID)"
    }

    private static func isCompleteModelDirectory(_ url: URL) -> Bool {
        requiredModelArtifacts.allSatisfy { containsModelArtifact(named: $0, in: url) }
    }

    private static func containsModelArtifact(named artifactName: String, in directory: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return items.contains { item in
            let name = item.lastPathComponent
            return name == "\(artifactName).mlmodelc" || name == "\(artifactName).mlpackage"
        }
    }
}
