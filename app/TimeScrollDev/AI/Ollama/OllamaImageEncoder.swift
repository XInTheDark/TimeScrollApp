import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Encodes a frame as the base64 JPEG that Ollama's `/api/embed` expects in an input's `image` field.
enum OllamaImageEncoder {
    private static let ciContext = CIContext(options: [.priorityRequestLow: true, .cacheIntermediates: false])
    private static let quality: CGFloat = 0.8

    static func base64JPEG(from pixelBuffer: CVPixelBuffer) -> String? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
              ) else {
            return nil
        }
        return data.base64EncodedString()
    }
}
