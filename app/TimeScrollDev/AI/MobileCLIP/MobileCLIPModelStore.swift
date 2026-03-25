import CoreML
import Foundation

enum MobileCLIPModelStore {
    static func modelsRoot() -> URL {
        let root = StoragePaths.sharedSupportRoot()
            .appendingPathComponent("TimeScroll", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("MobileCLIP2", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func bundleURL(for model: MobileCLIPModelCatalog.Model) -> URL {
        modelsRoot().appendingPathComponent(model.rawValue, isDirectory: true)
    }

    static func isInstalled(_ model: MobileCLIPModelCatalog.Model) -> Bool {
        let bundle = bundleURL(for: model)
        let manifest = bundle.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    static func manifest(for model: MobileCLIPModelCatalog.Model) -> MobileCLIPManifest? {
        try? MobileCLIPManifestLoader.load(from: bundleURL(for: model))
    }

    static func remove(_ model: MobileCLIPModelCatalog.Model) throws {
        let url = bundleURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func imageEncoderURL(for model: MobileCLIPModelCatalog.Model) -> URL? {
        guard let manifest = manifest(for: model) else { return nil }
        return manifest.artifactPath(kind: "coreml-image-encoder", relativeTo: bundleURL(for: model))
    }

    static func textEncoderURL(for model: MobileCLIPModelCatalog.Model) -> URL? {
        guard let manifest = manifest(for: model) else { return nil }
        return manifest.artifactPath(kind: "coreml-text-encoder", relativeTo: bundleURL(for: model))
    }

    static func tokenizerDirectoryURL(for model: MobileCLIPModelCatalog.Model) -> URL {
        bundleURL(for: model).appendingPathComponent("tokenizer", isDirectory: true)
    }

    static func prepareCompiledArtifacts(for model: MobileCLIPModelCatalog.Model) throws -> (image: URL, text: URL) {
        guard let imageSourceURL = imageEncoderURL(for: model),
              let textSourceURL = textEncoderURL(for: model) else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing MobileCLIP2 model artifacts for \(model.rawValue)"])
        }

        let compiledRoot = bundleURL(for: model).appendingPathComponent("Compiled", isDirectory: true)
        try FileManager.default.createDirectory(at: compiledRoot, withIntermediateDirectories: true)

        let imageCompiledURL = compiledRoot.appendingPathComponent("image_encoder.mlmodelc", isDirectory: true)
        let textCompiledURL = compiledRoot.appendingPathComponent("text_encoder.mlmodelc", isDirectory: true)

        try ensureCompiledModel(sourceURL: imageSourceURL, destinationURL: imageCompiledURL)
        try ensureCompiledModel(sourceURL: textSourceURL, destinationURL: textCompiledURL)
        return (imageCompiledURL, textCompiledURL)
    }

    private static func ensureCompiledModel(sourceURL: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }

        let compiledTempURL = try MLModel.compileModel(at: sourceURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: compiledTempURL)
        } else {
            try FileManager.default.moveItem(at: compiledTempURL, to: destinationURL)
        }
    }
}
