import AppKit
import CoreImage
import CoreML
import CoreVideo
import Foundation

final class MobileCLIPRuntime {
    let model: MobileCLIPModelCatalog.Model
    let manifest: MobileCLIPManifest

    private let tokenizer: MobileCLIPTokenizer
    private let modelConfiguration: MLModelConfiguration
    private let imageModelURL: URL
    private let textModelURL: URL
    private let loadLock = NSLock()
    private var cachedImageModel: MLModel?
    private var cachedTextModel: MLModel?

    private static let ciContext = CIContext(options: nil)

    init(model: MobileCLIPModelCatalog.Model) throws {
        guard let manifest = MobileCLIPModelStore.manifest(for: model) else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 10, userInfo: [NSLocalizedDescriptionKey: "MobileCLIP2 model \(model.rawValue) is not installed"])
        }
        let compiledArtifacts = try MobileCLIPModelStore.prepareCompiledArtifacts(for: model)
        self.model = model
        self.manifest = manifest
        self.imageModelURL = compiledArtifacts.image
        self.textModelURL = compiledArtifacts.text
        self.tokenizer = try MobileCLIPTokenizer(
            tokenizerDirectoryURL: MobileCLIPModelStore.tokenizerDirectoryURL(for: model),
            contextLength: manifest.embedding.contextLength
        )
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.modelConfiguration = configuration
    }

    var dimension: Int { manifest.embedding.dimension }
    var contextLength: Int { manifest.embedding.contextLength }
    var imageSize: CGSize {
        CGSize(width: manifest.imagePreprocessing.resize, height: manifest.imagePreprocessing.resize)
    }

    func encodeText(text: String) throws -> (vector: [Float], tokenCount: Int, contextLength: Int) {
        let tokenCount = tokenizer.tokenCount(text: text)
        let tokens = tokenizer.encodeFull(text: text)
        let tokenArray = try MLMultiArray(shape: [NSNumber(value: 1), NSNumber(value: contextLength)], dataType: .int32)
        for (index, token) in tokens.enumerated() {
            tokenArray[index] = NSNumber(value: token)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "tokens": MLFeatureValue(multiArray: tokenArray)
        ])
        let output = try textModel().prediction(from: provider)
        guard let multiArray = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 11, userInfo: [NSLocalizedDescriptionKey: "Missing MobileCLIP2 text embedding output"])
        }
        return (multiArray.toFloatArray(), tokenCount, contextLength)
    }

    func encodeImage(pixelBuffer: CVPixelBuffer) throws -> [Float] {
        let prepared = try preprocess(pixelBuffer: pixelBuffer, targetSize: imageSize)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: prepared)
        ])
        let output = try imageModel().prediction(from: provider)
        guard let multiArray = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 12, userInfo: [NSLocalizedDescriptionKey: "Missing MobileCLIP2 image embedding output"])
        }
        return multiArray.toFloatArray()
    }

    private func imageModel() throws -> MLModel {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let cachedImageModel { return cachedImageModel }
        let loaded = try MLModel(contentsOf: imageModelURL, configuration: modelConfiguration)
        cachedImageModel = loaded
        return loaded
    }

    private func textModel() throws -> MLModel {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let cachedTextModel { return cachedTextModel }
        let loaded = try MLModel(contentsOf: textModelURL, configuration: modelConfiguration)
        cachedTextModel = loaded
        return loaded
    }

    private func preprocess(pixelBuffer: CVPixelBuffer, targetSize: CGSize) throws -> CVPixelBuffer {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let cropped = image.centerSquareCropped()
        let resized = cropped.resized(to: targetSize)
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            nil,
            Int(targetSize.width),
            Int(targetSize.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to create MobileCLIP2 input buffer"])
        }
        Self.ciContext.render(resized, to: output)
        return output
    }
}

private extension CIImage {
    func centerSquareCropped() -> CIImage {
        let size = min(extent.width, extent.height)
        let originX = round((extent.width - size) / 2.0)
        let originY = round((extent.height - size) / 2.0)
        let rect = CGRect(x: originX, y: originY, width: size, height: size)
        return cropped(to: rect).transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
    }

    func resized(to size: CGSize) -> CIImage {
        let scaleX = size.width / extent.width
        let scaleY = size.height / extent.height
        return transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}

private extension MLMultiArray {
    func toFloatArray() -> [Float] {
        let elementCount = self.count
        switch dataType {
        case .float32:
            return withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(elementCount)) }
        case .float16:
            return (0..<elementCount).map { self[$0].floatValue }
        case .double:
            return withUnsafeBufferPointer(ofType: Double.self) { Array($0.prefix(elementCount)).map(Float.init) }
        case .int32:
            return withUnsafeBufferPointer(ofType: Int32.self) { Array($0.prefix(elementCount)).map(Float.init) }
        @unknown default:
            return (0..<elementCount).map { self[$0].floatValue }
        }
    }

    func withUnsafeBufferPointer<T, Result>(ofType: T.Type, _ body: (UnsafeBufferPointer<T>) -> Result) -> Result {
        let elementCount = self.count
        let typedPointer = dataPointer.bindMemory(to: T.self, capacity: elementCount)
        let buffer = UnsafeBufferPointer(start: typedPointer, count: elementCount)
        return body(buffer)
    }
}
