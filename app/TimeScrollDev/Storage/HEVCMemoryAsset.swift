import AVFoundation
import Foundation

final class HEVCMemoryAsset: NSObject, AVAssetResourceLoaderDelegate {
  let asset: AVURLAsset
  private var data: Data?
  private let source: URL
  private let access: VaultMediaAccess.Token
  private let contentType: AVFileType
  private let lock = NSLock()
  private static let queue = DispatchQueue(label: "TimeScroll.HEVC.MemoryReader", qos: .userInitiated)

  init(data: Data, source: URL, access: VaultMediaAccess.Token, mime: String = "video/quicktime") {
    self.data = data
    self.source = source
    self.access = access
    contentType = Self.fileType(forMime: mime)
    let ext: String
    switch contentType {
    case .mp4: ext = "mp4"
    case .m4a: ext = "m4a"
    case .caf: ext = "caf"
    default: ext = "mov"
    }
    asset = AVURLAsset(url: URL(string: "timescroll-memory://\(UUID().uuidString)/media.\(ext)")!)
    super.init()
    asset.resourceLoader.setDelegate(self, queue: Self.queue)
  }

  func invalidate() {
    lock.lock()
    data = nil
    lock.unlock()
    asset.cancelLoading()
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let data, VaultMediaAccess.isCurrent(access, for: source) else {
      request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
      return true
    }
    if let info = request.contentInformationRequest {
      info.contentType = contentType.rawValue
      info.contentLength = Int64(data.count)
      info.isByteRangeAccessSupported = true
    }
    if let read = request.dataRequest {
      let offset = max(read.requestedOffset, read.currentOffset)
      guard offset >= 0, offset <= Int64(data.count), read.requestedLength >= 0 else {
        request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
        return true
      }
      let start = Int(offset)
      let length = read.requestsAllDataToEndOfResource ? data.count - start : min(read.requestedLength, data.count - start)
      read.respond(with: data.subdata(in: start..<(start + length)))
    }
    request.finishLoading()
    return true
  }

  /// Container type for a decrypted TSE payload's mime.
  static func fileType(forMime mime: String) -> AVFileType {
    switch mime.lowercased() {
    case "video/mp4": return .mp4
    case "audio/mp4", "audio/m4a", "audio/x-m4a": return .m4a
    case "audio/x-caf": return .caf
    default: return .mov
    }
  }
}
