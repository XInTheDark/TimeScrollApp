import Foundation
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
import ImageIO
import Accelerate

struct EncodedImage {
    let data: Data
    let format: String    // "heic", "jpg", "png"
    let width: Int
    let height: Int
}

enum ImageEncoderError: Error { case destinationFailed }

final class ImageEncoder {
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: true,
        .cacheIntermediates: false
    ])

    func encode(
        cgImage: CGImage,
        format: SettingsStore.StorageFormat,
        maxLongEdge: Int,
        quality: Double
    ) throws -> EncodedImage {
        // Prefer CI-based resize + encode to offload work from CPU
        if let ciEncoded = try encodeWithCoreImage(cgImage: cgImage, format: format, maxLongEdge: maxLongEdge, quality: quality) {
            return ciEncoded
        }
        // Fallback to existing CPU path (unchanged)
        let resized = (maxLongEdge > 0) ? try resizeIfNeeded(cgImage: cgImage, maxLongEdge: maxLongEdge) : cgImage
        let (utType, fmt) = resolveUTType(format: format)
        if utType == nil && format == .heic {
            // Fallback to JPEG if HEIC not available on this system
            return try encode(cgImage: resized, format: .jpeg, maxLongEdge: 0, quality: quality)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, (utType ?? UTType.jpeg).identifier as CFString, 1, nil) else {
            throw ImageEncoderError.destinationFailed
        }
        var props: [CFString: Any] = [:]
        if fmt != "png" {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, resized, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageEncoderError.destinationFailed }
        return EncodedImage(data: data as Data, format: fmt, width: resized.width, height: resized.height)
    }

    // Encode directly from CVPixelBuffer to avoid CGImage creation costs.
    func encode(
        pixelBuffer: CVPixelBuffer,
        format: SettingsStore.StorageFormat,
        maxLongEdge: Int,
        quality: Double
    ) throws -> EncodedImage {
        let w0 = CVPixelBufferGetWidth(pixelBuffer)
        let h0 = CVPixelBufferGetHeight(pixelBuffer)
        var outW = w0
        var outH = h0
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        let longEdge = max(w0, h0)
        if maxLongEdge > 0 && longEdge > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(longEdge)
            outW = max(1, Int(Double(w0) * scale))
            outH = max(1, Int(Double(h0) * scale))
            ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0
            ])
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let opts: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality
        ]
        switch format {
        case .heic:
            if #available(macOS 10.13, *) {
                if let data = ciContext.heifRepresentation(of: ci, format: .RGBA8, colorSpace: cs, options: opts) {
                    return EncodedImage(data: data, format: "heic", width: outW, height: outH)
                } else {
                    // Fallback to JPEG if HEIC not supported by hardware
                    return try encode(pixelBuffer: pixelBuffer, format: .jpeg, maxLongEdge: maxLongEdge, quality: quality)
                }
            } else {
                return try encode(pixelBuffer: pixelBuffer, format: .jpeg, maxLongEdge: maxLongEdge, quality: quality)
            }
        case .jpeg:
            if let data = ciContext.jpegRepresentation(of: ci, colorSpace: cs, options: opts) {
                return EncodedImage(data: data, format: "jpg", width: outW, height: outH)
            }
            // Fallback path: render to CGImage then reuse CPU path
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                return try encode(cgImage: cg, format: .jpeg, maxLongEdge: 0, quality: quality)
            }
            throw ImageEncoderError.destinationFailed
        case .png:
            if let data = ciContext.pngRepresentation(of: ci, format: .RGBA8, colorSpace: cs, options: [:]) {
                return EncodedImage(data: data, format: "png", width: outW, height: outH)
            }
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                return try encode(cgImage: cg, format: .png, maxLongEdge: 0, quality: quality)
            }
            throw ImageEncoderError.destinationFailed
        }
    }

    // MARK: - Core Image path (preferred)
    private func encodeWithCoreImage(
        cgImage: CGImage,
        format: SettingsStore.StorageFormat,
        maxLongEdge: Int,
        quality: Double
    ) throws -> EncodedImage? {
        let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var ci = CIImage(cgImage: cgImage)
        let w = Double(cgImage.width), h = Double(cgImage.height)
        let longEdge = max(w, h)
        var outW = Int(w), outH = Int(h)
        if maxLongEdge > 0, longEdge > Double(maxLongEdge) {
            let scale = Double(maxLongEdge) / longEdge
            ci = ci
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1.0
                ])
            outW = max(1, Int(w * scale))
            outH = max(1, Int(h * scale))
        }
        let opts: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality
        ]
        switch format {
        case .heic:
            if #available(macOS 10.13, *) {
                if let data = ciContext.heifRepresentation(of: ci, format: .RGBA8, colorSpace: cs, options: opts) {
                    return EncodedImage(data: data, format: "heic", width: outW, height: outH)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        case .jpeg:
            if let data = ciContext.jpegRepresentation(of: ci, colorSpace: cs, options: opts) {
                return EncodedImage(data: data, format: "jpg", width: outW, height: outH)
            }
            return nil
        case .png:
            if let data = ciContext.pngRepresentation(of: ci, format: .RGBA8, colorSpace: cs, options: [:]) {
                return EncodedImage(data: data, format: "png", width: outW, height: outH)
            }
            return nil
        }
    }
    private func resolveUTType(format: SettingsStore.StorageFormat) -> (UTType?, String) {
        switch format {
        case .heic:
            if #available(macOS 11.0, *) { return (UTType.heic, "heic") }
            return (nil, "heic")
        case .jpeg:
            if #available(macOS 11.0, *) { return (UTType.jpeg, "jpg") }
            return (nil, "jpg")
        case .png:
            if #available(macOS 11.0, *) { return (UTType.png, "png") }
            return (nil, "png")
        }
    }

    private func resizeIfNeeded(cgImage: CGImage, maxLongEdge: Int) throws -> CGImage {
        let w = cgImage.width, h = cgImage.height
        let longEdge = max(w, h)
        guard maxLongEdge > 0 && longEdge > maxLongEdge else { return cgImage }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))

        var srcFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        var srcBuffer = vImage_Buffer()
        var destBuffer = vImage_Buffer()
        defer {
            free(srcBuffer.data)
            free(destBuffer.data)
        }
        guard vImageBuffer_InitWithCGImage(&srcBuffer, &srcFormat, nil, cgImage, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return cgImage }
        guard vImageBuffer_Init(&destBuffer, vImagePixelCount(newH), vImagePixelCount(newW), 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return cgImage }
        guard vImageScale_ARGB8888(&srcBuffer, &destBuffer, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return cgImage }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let ctx = CGContext(
            data: destBuffer.data,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: destBuffer.rowBytes,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return cgImage }
        guard let out = ctx.makeImage() else { return cgImage }
        return out
    }
}
