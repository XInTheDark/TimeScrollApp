import Foundation
import AppKit
import ImageIO

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let hevcCache = NSCache<NSString, NSImage>()
    private init() {
        cache.countLimit = 500
        hevcCache.countLimit = 500
    }

    func clear() { cache.removeAllObjects() }

    func thumbnail(for url: URL, maxPixel: CGFloat = 320) -> NSImage? {
        let key = url.path as NSString
        if let img = cache.object(forKey: key) {
            return img
        }
        var src: CGImageSource?
        if url.pathExtension.lowercased() == "mov" {
            // HEVC video (plaintext) – we cannot deduce timestamp here; caller should prefer HEVCFrameExtractor.image(...)
            return nil
        }
        if url.pathExtension.lowercased() == "tse" {
            // Encrypted container: peek header; only use ImageIO when payload is image/*
            let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")
            if unlocked, let (header, blob) = try? FileCrypter.shared.decryptTSE(at: url) {
                if header.mime.hasPrefix("image/") {
                    src = CGImageSourceCreateWithData(blob as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        } else {
            src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let src = src else { return nil }
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

    // Asynchronous HEVC thumbnail fetch with in-memory cache
    func hevcThumbnail(for url: URL, startedAtMs: Int64, maxPixel: CGFloat = 320, completion: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)#\(startedAtMs)#\(Int(maxPixel))" as NSString
        if let img = hevcCache.object(forKey: key) { completion(img); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = HEVCFrameExtractor.image(forPath: url, startedAtMs: startedAtMs, format: "hevc", maxPixel: maxPixel)
            if let img = img { self.hevcCache.setObject(img, forKey: key) }
            DispatchQueue.main.async { completion(img) }
        }
    }
}
