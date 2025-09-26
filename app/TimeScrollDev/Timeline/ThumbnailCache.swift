import Foundation
import AppKit
import ImageIO

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {
        cache.countLimit = 500
    }

    func thumbnail(for url: URL, maxPixel: CGFloat = 320) -> NSImage? {
        let key = url.path as NSString
        if let img = cache.object(forKey: key) {
            return img
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else {
            // Fallback: load full image and let NSImage scale
            if let full = (try? Data(contentsOf: url)).flatMap({ CGImageSourceCreateWithData($0 as CFData, nil) }).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
                let nsImage = NSImage(cgImage: full, size: NSSize(width: full.width, height: full.height))
                cache.setObject(nsImage, forKey: key)
                return nsImage
            }
            return nil
        }
        let nsImage = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
        cache.setObject(nsImage, forKey: key)
        return nsImage
    }
}
