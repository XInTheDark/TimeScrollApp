import AppKit
import CoreImage
import ImageIO

/// Export-scoped readers avoid seeking and rebuilding a decoder for every snapshot.
final class TimelapseImageLoader {
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let maxPixel: CGFloat?
  private var readers: [URL: (reader: TimelapseSegmentReader?, startMs: Int64, access: VaultMediaAccess.Token, size: Int, modified: Date)] = [:]
  private var recent: [URL] = []

  init(maxPixel: CGFloat? = nil) { self.maxPixel = maxPixel }

  func load(_ frame: TimelapseFrame, check: () throws -> Void) async throws -> (image: CGImage, usedPreview: Bool)? {
    let url = URL(fileURLWithPath: frame.path)
    guard let access = VaultMediaAccess.token(for: url) else { throw TimelapseError.locked }
    try check()
    var image: CGImage?
    let ext = url.pathExtension.lowercased()
    let video = frame.format.lowercased() == "hevc" || ext == "mov" || ext == "mp4"
      || (ext == "tse" && (try? FileCrypter.shared.peekTSEHeader(at: url).mime.hasPrefix("video/")) == true)
    if video {
      image = HEVCLiveFrameCache.shared.image(path: url, startedAtMs: frame.timeMs)?
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
      if image == nil { image = try await videoImage(url: url, timeMs: frame.timeMs, check: check) }
      if image == nil && ext == "tse" {
        image = try await videoImage(url: url.deletingPathExtension().appendingPathExtension("mov"), timeMs: frame.timeMs, check: check)
      }
    } else {
      image = stillImage(url: url)
    }
    var usedPreview = false
    if image == nil, let path = frame.thumbPath {
      let preview = URL(fileURLWithPath: path)
      guard let previewAccess = VaultMediaAccess.token(for: preview) else { throw TimelapseError.locked }
      image = stillImage(url: preview)
      guard VaultMediaAccess.isCurrent(previewAccess, for: preview) else { throw TimelapseError.locked }
      usedPreview = image != nil
    }
    try check()
    guard VaultMediaAccess.isCurrent(access, for: url) else { throw TimelapseError.locked }
    return image.map { ($0, usedPreview) }
  }

  private func videoImage(url: URL, timeMs: Int64, check: () throws -> Void) async throws -> CGImage? {
    guard let access = VaultMediaAccess.token(for: url) else { throw TimelapseError.locked }
    guard let info = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = info[.size] as? Int, let modified = info[.modificationDate] as? Date else { return nil }
    if let cached = readers[url], cached.access != access || cached.size != size || cached.modified != modified {
      readers.removeValue(forKey: url)
    }
    if readers[url] == nil {
      var reader: TimelapseSegmentReader?
      if let entry = HEVCAssetCache.shared.entry(for: url) {
        reader = try? await TimelapseSegmentReader(entry: entry, context: context, maxPixel: maxPixel)
      }
      readers[url] = (reader, TimelapseSegmentTime.startMs(for: url) ?? timeMs, access, size, modified)
    }
    recent.removeAll { $0 == url }
    recent.append(url)
    while recent.count > 2 { readers.removeValue(forKey: recent.removeFirst()) }
    guard let cached = readers[url] else { return nil }
    let image = try cached.reader?.image(at: max(0, timeMs - cached.startMs), check: check)
    guard VaultMediaAccess.isCurrent(access, for: url) else { throw TimelapseError.locked }
    return image
  }

  private func stillImage(url: URL) -> CGImage? {
    let source: CGImageSource?
    if url.pathExtension.lowercased() == "tse" {
      guard let (header, data) = try? FileCrypter.shared.decryptTSE(at: url), header.mime.hasPrefix("image/") else { return nil }
      source = CGImageSourceCreateWithData(data as CFData, nil)
    } else {
      source = CGImageSourceCreateWithURL(url as CFURL, nil)
    }
    guard let source else { return nil }
    if let maxPixel {
      return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
      ] as CFDictionary)
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}
