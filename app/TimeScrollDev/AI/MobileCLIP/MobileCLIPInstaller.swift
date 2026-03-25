import CryptoKit
import Foundation

enum MobileCLIPInstaller {
    typealias ProgressHandler = @Sendable (Double) -> Void

    static func install(
        model: MobileCLIPModelCatalog.Model,
        progressHandler: ProgressHandler? = nil
    ) async throws -> MobileCLIPLatestRelease {
        let release = try await MobileCLIPReleaseService.fetchLatestRelease()
        guard let asset = release.asset(for: model) else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 2, userInfo: [NSLocalizedDescriptionKey: "No release asset is available for \(model.rawValue) in the latest MobileCLIP2-coreml release"])
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let archiveURL = tempRoot.appendingPathComponent(asset.name)
        try await download(asset: asset, to: archiveURL, progressHandler: progressHandler)
        try verifyChecksumIfPresent(asset: asset, archiveURL: archiveURL)

        let unzipRoot = tempRoot.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipRoot, withIntermediateDirectories: true)
        try unzipArchive(at: archiveURL, to: unzipRoot)

        let extractedBundleURL = unzipRoot.appendingPathComponent(model.rawValue, isDirectory: true)
        let extractedManifestURL = extractedBundleURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: extractedManifestURL.path) else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Downloaded archive for \(model.rawValue) is missing manifest.json"])
        }

        let destinationURL = MobileCLIPModelStore.bundleURL(for: model)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.createDirectory(at: MobileCLIPModelStore.modelsRoot(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: extractedBundleURL, to: destinationURL)
        _ = try MobileCLIPModelStore.prepareCompiledArtifacts(for: model)
        return release
    }

    static func remove(model: MobileCLIPModelCatalog.Model) throws {
        try MobileCLIPModelStore.remove(model)
    }

    private static func download(
        asset: MobileCLIPReleaseAsset,
        to destinationURL: URL,
        progressHandler: ProgressHandler?
    ) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let (temporaryURL, response): (URL, URLResponse) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            var observation: NSKeyValueObservation?

            let task = session.downloadTask(with: asset.downloadURL) { temporaryURL, response, error in
                observation?.invalidate()
                observation = nil

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let temporaryURL, let response else {
                    continuation.resume(throwing: NSError(domain: "TimeScroll.MobileCLIP", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(asset.name)"]))
                    return
                }

                progressHandler?(1.0)
                continuation.resume(returning: (temporaryURL, response))
            }

            if let progressHandler {
                progressHandler(0)
                observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    let clamped = max(0, min(1, progress.fractionCompleted))
                    progressHandler(clamped)
                }
            }

            task.resume()
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to download \(asset.name)"])
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    private static func verifyChecksumIfPresent(asset: MobileCLIPReleaseAsset, archiveURL: URL) throws {
        guard let expected = asset.sha256?.lowercased(), !expected.isEmpty else { return }
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 5, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(asset.name)"])
        }
    }

    private static func unzipArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to unpack \(archiveURL.lastPathComponent)"])
        }
    }
}
