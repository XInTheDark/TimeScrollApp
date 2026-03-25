import AppKit
import CoreImage
import CoreVideo
import Foundation

enum SnapshotImageLoader {
    private static let ciContext = CIContext(options: nil)

    static func loadPixelBuffer(for row: DB.EmbeddingRebuildRow) -> CVPixelBuffer? {
        if let thumbPath = row.thumbPath,
           let buffer = loadPixelBuffer(from: URL(fileURLWithPath: thumbPath), startedAtMs: row.startedAtMs) {
            return buffer
        }
        return loadPixelBuffer(from: URL(fileURLWithPath: row.path), startedAtMs: row.startedAtMs)
    }

    private static func loadPixelBuffer(from url: URL, startedAtMs: Int64) -> CVPixelBuffer? {
        let ext = url.pathExtension.lowercased()
        let image: NSImage?
        if ext == "mov" || ext == "tse" {
            image = HEVCFrameExtractor.image(forPath: url, startedAtMs: startedAtMs, format: "hevc", maxPixel: 1024)
                ?? ThumbnailCache.shared.thumbnail(for: url, maxPixel: 1024)
        } else {
            image = ThumbnailCache.shared.thumbnail(for: url, maxPixel: 1024)
        }
        guard let image else { return nil }
        return pixelBuffer(from: image)
    }

    private static func pixelBuffer(from image: NSImage) -> CVPixelBuffer? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        ciContext.render(CIImage(cgImage: cgImage), to: pixelBuffer)
        return pixelBuffer
    }
}
