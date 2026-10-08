import AppKit
import CoreImage
import CoreVideo
import Foundation

/// Holds the newest captured HEVC frame at full resolution. A live segment only writes a frame
/// once the next one arrives, so without this the stage could show just the small poster for it.
final class HEVCLiveFrameCache {
  static let shared = HEVCLiveFrameCache()

  private struct Entry {
    let path: String
    let startedAtMs: Int64
    let image: CGImage
    let access: VaultMediaAccess.Token
  }

  private let lock = NSLock()
  private var entry: Entry?
  private let ciContext = CIContext(options: nil)
  private var observer: NSObjectProtocol?

  private init() {
    observer = DistributedNotificationCenter.default().addObserver(forName: VaultMediaAccess.didChange, object: nil, queue: nil) { [weak self] _ in
      self?.clear()
    }
  }

  /// Stores the frame just appended to `path`; replaces the previous one. Call off the main thread.
  func store(pixelBuffer: CVPixelBuffer, path: URL, startedAtMs: Int64) {
    guard let access = VaultMediaAccess.token(for: path) else { return }
    let ci = CIImage(cvPixelBuffer: pixelBuffer)
    guard let image = ciContext.createCGImage(ci, from: ci.extent) else { return }
    lock.lock()
    entry = Entry(path: path.path, startedAtMs: startedAtMs, image: image, access: access)
    lock.unlock()
  }

  func image(path: URL, startedAtMs: Int64) -> NSImage? {
    lock.lock()
    let current = entry
    lock.unlock()
    guard let current, current.path == path.path, current.startedAtMs == startedAtMs,
          VaultMediaAccess.isCurrent(current.access, for: path) else { return nil }
    return NSImage(cgImage: current.image, size: NSSize(width: current.image.width, height: current.image.height))
  }

  func clear() {
    lock.lock()
    entry = nil
    lock.unlock()
  }
}
