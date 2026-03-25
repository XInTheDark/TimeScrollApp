import CoreVideo
import Foundation

final class MobileCLIP2EmbeddingProvider {
    let model: MobileCLIPModelCatalog.Model
    let dim: Int
    let contextLength: Int

    private static let cacheLock = NSLock()
    private static var runtimeCache: [MobileCLIPModelCatalog.Model: MobileCLIPRuntime] = [:]

    init?(modelName: String, eagerlyLoadRuntime: Bool = true) {
        guard let model = MobileCLIPModelCatalog.Model(rawValue: modelName) else { return nil }
        self.model = model
        if eagerlyLoadRuntime {
            guard let runtime = Self.runtime(for: model) else { return nil }
            self.dim = runtime.dimension
            self.contextLength = runtime.contextLength
        } else if let manifest = Self.manifest(for: model) {
            self.dim = manifest.embedding.dimension
            self.contextLength = manifest.embedding.contextLength
        } else if MobileCLIPModelStore.isInstalled(model) {
            self.dim = model.embeddingDimension
            self.contextLength = 0
        } else {
            self.dim = 0
            self.contextLength = 0
        }
    }

    func embedTextWithStats(text: String) -> ([Float], Int, Int) {
        guard let runtime = Self.runtime(for: model) else {
            Self.logDebug("[AI][MobileCLIP][Text][Error] model=\(model.rawValue) err=Runtime unavailable")
            return ([], 0, contextLength)
        }
        do {
            let result = try runtime.encodeText(text: text)
            return (EmbeddingService.l2normalize(result.vector), result.tokenCount, result.contextLength)
        } catch {
            Self.logDebug("[AI][MobileCLIP][Text][Error] model=\(model.rawValue) err=\(error.localizedDescription)")
            return ([], 0, contextLength)
        }
    }

    func embedDocument(pixelBuffer: CVPixelBuffer, extractedText: String?, includeText: Bool) -> [Float] {
        guard let runtime = Self.runtime(for: model) else {
            Self.logDebug("[AI][MobileCLIP][Image][Error] model=\(model.rawValue) err=Runtime unavailable")
            return []
        }
        do {
            let imageVector = EmbeddingService.l2normalize(try runtime.encodeImage(pixelBuffer: pixelBuffer))
            guard includeText, let extractedText, !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return imageVector
            }
            let textVector = embedTextWithStats(text: extractedText).0
            guard !textVector.isEmpty else { return imageVector }
            return Self.fuse(imageVector: imageVector, textVector: textVector)
        } catch {
            Self.logDebug("[AI][MobileCLIP][Image][Error] model=\(model.rawValue) err=\(error.localizedDescription)")
            return []
        }
    }

    static func isInstalled(modelName: String) -> Bool {
        guard let model = MobileCLIPModelCatalog.Model(rawValue: modelName) else { return false }
        return MobileCLIPModelStore.isInstalled(model)
    }

    static func availableDimension(modelName: String) -> Int {
        guard let model = MobileCLIPModelCatalog.Model(rawValue: modelName) else { return 0 }

        cacheLock.lock()
        let cachedRuntime = runtimeCache[model]
        cacheLock.unlock()

        if let cachedRuntime {
            return cachedRuntime.dimension
        }
        if let manifest = manifest(for: model) {
            return manifest.embedding.dimension
        }
        return MobileCLIPModelStore.isInstalled(model) ? model.embeddingDimension : 0
    }

    static func invalidate(modelName: String) {
        guard let model = MobileCLIPModelCatalog.Model(rawValue: modelName) else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        runtimeCache.removeValue(forKey: model)
    }

    private static func runtime(for model: MobileCLIPModelCatalog.Model) -> MobileCLIPRuntime? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = runtimeCache[model] {
            return cached
        }
        do {
            let runtime = try MobileCLIPRuntime(model: model)
            runtimeCache[model] = runtime
            return runtime
        } catch {
            logDebug("[AI][MobileCLIP][Init][Error] model=\(model.rawValue) err=\(error.localizedDescription)")
            return nil
        }
    }

    private static func manifest(for model: MobileCLIPModelCatalog.Model) -> MobileCLIPManifest? {
        MobileCLIPModelStore.manifest(for: model)
    }

    private static func fuse(imageVector: [Float], textVector: [Float]) -> [Float] {
        let count = min(imageVector.count, textVector.count)
        guard count > 0 else { return imageVector }
        var blended = Array(repeating: Float(0), count: count)
        let imageWeight: Float = 0.40
        let textWeight: Float = 0.60
        for index in 0..<count {
            blended[index] = imageVector[index] * imageWeight + textVector[index] * textWeight
        }
        return EmbeddingService.l2normalize(blended)
    }

    private static func logDebug(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "settings.debugMode") else { return }
        print(message)
    }
}
