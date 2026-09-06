import AVFoundation
import Foundation

final class HEVCMemoryAsset: NSObject, AVAssetResourceLoaderDelegate {
  let asset: AVURLAsset
  private var data: Data?
  private let source: URL
  private let access: VaultMediaAccess.Token
  private let lock = NSLock()
  private static let queue = DispatchQueue(label: "TimeScroll.HEVC.MemoryReader", qos: .userInitiated)

  init(data: Data, source: URL, access: VaultMediaAccess.Token) {
    self.data = data
    self.source = source
    self.access = access
    asset = AVURLAsset(url: URL(string: "timescroll-memory://\(UUID().uuidString)/segment.mov")!)
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
      info.contentType = AVFileType.mov.rawValue
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
}
