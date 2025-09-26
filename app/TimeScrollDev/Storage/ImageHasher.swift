import CoreVideo
import CoreImage
import Accelerate

final class ImageHasher {
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: true,
        .cacheIntermediates: false
    ])

    func hash64(pixelBuffer: CVPixelBuffer) -> UInt64 {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            return hash64NV12(pixelBuffer)
        }
        // Fallback to CI-based path for other formats
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = max(1.0, ci.extent.width)
        let scale = 8.0 / w
        let resized = ci
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let cg = ciContext.createCGImage(resized, from: CGRect(x: 0, y: 0, width: 9, height: 8)) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: 9*8*4)
        guard let ctx = CGContext(data: &pixels,
                                  width: 9,
                                  height: 8,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 9*4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var h: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let idxA = (y*9 + x)*4
                let idxB = (y*9 + x + 1)*4
                let a = 0.299*Double(pixels[idxA]) + 0.587*Double(pixels[idxA+1]) + 0.114*Double(pixels[idxA+2])
                let b = 0.299*Double(pixels[idxB]) + 0.587*Double(pixels[idxB+1]) + 0.114*Double(pixels[idxB+2])
                if a > b { h |= (1 << bit) }
                bit += 1
            }
        }
        return h
    }

    private func hash64NV12(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard w > 1 && h > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Sample 9 values per row (for 8 comparisons) across 8 rows.
        var hval: UInt64 = 0
        var bit = 0
        let stepY = Double(h) / 8.0
        let stepX = Double(w) / 9.0
        for ry in 0..<8 {
            let sy = min(h - 1, Int((Double(ry) + 0.5) * stepY))
            // Pre-sample 9 luma values across the row
            var rowSamples = [UInt8](repeating: 0, count: 9)
            for rx in 0..<9 {
                let sx = min(w - 1, Int((Double(rx) + 0.5) * stepX))
                let offset = sy * stride + sx
                rowSamples[rx] = ptr[offset]
            }
            for x in 0..<8 {
                if rowSamples[x] > rowSamples[x+1] {
                    hval |= (1 << bit)
                }
                bit += 1
            }
        }
        return hval
    }

    func hash64(cgImage: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: 9*8*4)
        guard let ctx = CGContext(data: &pixels,
                                  width: 9,
                                  height: 8,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 9*4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var h: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let idxA = (y*9 + x)*4
                let idxB = (y*9 + x + 1)*4
                let a = 0.299*Double(pixels[idxA]) + 0.587*Double(pixels[idxA+1]) + 0.114*Double(pixels[idxA+2])
                let b = 0.299*Double(pixels[idxB]) + 0.587*Double(pixels[idxB+1]) + 0.114*Double(pixels[idxB+2])
                if a > b { h |= (1 << bit) }
                bit += 1
            }
        }
        return h
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        return Int((a ^ b).nonzeroBitCount)
    }
}
