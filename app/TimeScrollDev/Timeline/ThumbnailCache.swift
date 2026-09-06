import Foundation
import AppKit
import ImageIO

final class ThumbnailCache {
  static let shared = ThumbnailCache()
  private let cache = NSCache<NSString, NSImage>()
  private let hevcCache = NSCache<NSString, NSImage>()
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 3
    queue.qualityOfService = .userInitiated
    return queue
  }()
  private struct Request: Hashable {
    let key: String
    let generation: UInt64
    let video: Bool
    let access: VaultMediaAccess.Token
  }
  private var pending: [Request: [(NSImage?) -> Void]] = [:]
  private var generation: UInt64 = 0
  private let lock = NSLock()

  private init() {
    cache.countLimit = 500
    hevcCache.countLimit = 500
    cache.totalCostLimit = 64 * 1024 * 1024
    hevcCache.totalCostLimit = 64 * 1024 * 1024
  }

  func clear() {
    HEVCAssetCache.shared.clear()
    lock.lock()
    generation &+= 1
    cache.removeAllObjects()
    hevcCache.removeAllObjects()
    let callbacks = pending.values.flatMap { $0 }
    pending.removeAll()
    lock.unlock()
    DispatchQueue.main.async { callbacks.forEach { $0(nil) } }
  }

  func thumbnail(for url: URL, maxPixel: CGFloat = 320) -> NSImage? {
    guard let access = VaultMediaAccess.token(for: url) else { return nil }
    let key = "\(access.generation ?? "plain")#\(access.vaultEnabled)#\(url.path)#\(Int(maxPixel))" as NSString
    lock.lock()
    let ticket = generation
    let cached = cache.object(forKey: key)
    lock.unlock()
    let image = cached ?? loadThumbnail(for: url, maxPixel: maxPixel)
    lock.lock()
    defer { lock.unlock() }
    guard ticket == generation, VaultMediaAccess.isCurrent(access, for: url) else { return nil }
    if let image, cached == nil { cache.setObject(image, forKey: key, cost: cost(of: image)) }
    return image
  }

  func hevcThumbnail(for url: URL, startedAtMs: Int64, maxPixel: CGFloat = 320, completion: @escaping (NSImage?) -> Void) {
    loadAsync(url: url, key: "\(url.path)#\(startedAtMs)#\(Int(maxPixel))", video: true, completion: completion) {
      HEVCFrameExtractor.image(forPath: url, startedAtMs: startedAtMs, format: "hevc", maxPixel: maxPixel)
    }
  }

  func thumbnailAsync(for url: URL, maxPixel: CGFloat = 320, completion: @escaping (NSImage?) -> Void) {
    loadAsync(url: url, key: "\(url.path)#\(Int(maxPixel))", video: false, completion: completion) {
      self.loadThumbnail(for: url, maxPixel: maxPixel)
    }
  }

  private func loadAsync(url: URL, key: String, video: Bool, completion: @escaping (NSImage?) -> Void, load: @escaping () -> NSImage?) {
    guard let access = VaultMediaAccess.token(for: url) else {
      DispatchQueue.main.async { completion(nil) }
      return
    }
    let key = "\(access.generation ?? "plain")#\(access.vaultEnabled)#\(key)"
    lock.lock()
    let request = Request(key: key, generation: generation, video: video, access: access)
    let target = video ? hevcCache : cache
    if let image = target.object(forKey: key as NSString) {
      lock.unlock()
      deliver([completion], image: image, request: request, access: access, url: url)
      return
    }
    if pending[request] != nil {
      pending[request]?.append(completion)
      lock.unlock()
      return
    }
    pending[request] = [completion]
    lock.unlock()

    queue.addOperation {
      self.lock.lock()
      let active = request.generation == self.generation
      self.lock.unlock()
      let image = active && VaultMediaAccess.isCurrent(access, for: url) ? load() : nil
      self.lock.lock()
      let current = request.generation == self.generation && VaultMediaAccess.isCurrent(access, for: url)
      if current, let image { target.setObject(image, forKey: key as NSString, cost: self.cost(of: image)) }
      let callbacks = self.pending.removeValue(forKey: request) ?? []
      self.lock.unlock()
      self.deliver(callbacks, image: current ? image : nil, request: request, access: access, url: url)
    }
  }

  private func deliver(_ callbacks: [(NSImage?) -> Void], image: NSImage?, request: Request, access: VaultMediaAccess.Token, url: URL) {
    DispatchQueue.main.async {
      for callback in callbacks {
        self.lock.lock()
        let current = request.generation == self.generation
        self.lock.unlock()
        callback(current && VaultMediaAccess.isCurrent(access, for: url) ? image : nil)
      }
    }
  }

  private func cost(of image: NSImage) -> Int {
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
      .map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * 4)
  }

  private func loadThumbnail(for url: URL, maxPixel: CGFloat) -> NSImage? {
    guard VaultMediaAccess.token(for: url) != nil else { return nil }
    let ext = url.pathExtension.lowercased()
    if ext == "mov" { return nil }
    let source: CGImageSource?
    if ext == "tse" {
      guard let (header, data) = try? FileCrypter.shared.decryptTSE(at: url), header.mime.hasPrefix("image/") else { return nil }
      source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    } else {
      source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
    guard let source else { return nil }
    let options: CFDictionary = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
      kCGImageSourceShouldCache: false
    ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
      ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
