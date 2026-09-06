import AVFoundation
import Foundation

final class HEVCAssetCache {
  static let shared = HEVCAssetCache()

  final class Entry {
    let asset: AVURLAsset
    let memory: HEVCMemoryAsset?
    let cost: Int
    init(asset: AVURLAsset, memory: HEVCMemoryAsset? = nil, cost: Int = 0) {
      self.asset = asset
      self.memory = memory
      self.cost = cost
    }
    func invalidate() { memory?.invalidate(); asset.cancelLoading() }
  }

  private struct Key: Hashable {
    let path: URL
    let size: Int
    let modified: Date
    let access: VaultMediaAccess.Token
  }
  private struct Cached {
    let entry: Entry
    var used: UInt64
  }
  private final class Loading {
    let group = DispatchGroup()
    var entry: Entry?
    init() { group.enter() }
  }
  private let lock = NSLock()
  private var entries: [Key: Cached] = [:]
  private var loading: [Key: Loading] = [:]
  private var generation: UInt64 = 0
  private var clock: UInt64 = 0
  private let byteLimit = 64 * 1024 * 1024
  private var observer: NSObjectProtocol?

  private init() {
    observer = DistributedNotificationCenter.default().addObserver(forName: VaultMediaAccess.didChange, object: nil, queue: nil) { [weak self] _ in
      self?.clear()
    }
  }

  func clear() {
    lock.lock()
    generation &+= 1
    let old = entries.values.map(\.entry)
    entries.removeAll()
    loading.removeAll()
    lock.unlock()
    old.forEach { $0.invalidate() }
  }

  func entry(for path: URL) -> Entry? {
    guard let access = VaultMediaAccess.token(for: path),
          let info = try? FileManager.default.attributesOfItem(atPath: path.path),
          let size = info[.size] as? Int, let modified = info[.modificationDate] as? Date else { return nil }
    let key = Key(path: path, size: size, modified: modified, access: access)
    lock.lock()
    if var cached = entries[key] {
      clock &+= 1
      cached.used = clock
      entries[key] = cached
      lock.unlock()
      return VaultMediaAccess.isCurrent(access, for: path) ? cached.entry : nil
    }
    if let pending = loading[key] {
      let ticket = generation
      lock.unlock()
      pending.group.wait()
      lock.lock()
      let result = ticket == generation ? pending.entry : nil
      lock.unlock()
      return VaultMediaAccess.isCurrent(access, for: path) ? result : nil
    }
    let pending = Loading()
    loading[key] = pending
    let ticket = generation
    lock.unlock()

    let built: Entry?
    if path.pathExtension.lowercased() == "tse" {
      if let header = try? FileCrypter.shared.peekTSEHeader(at: path), header.mime.hasPrefix("video/"),
         let (verified, data) = try? FileCrypter.shared.decryptTSE(at: path), verified.mime.hasPrefix("video/") {
        let memory = HEVCMemoryAsset(data: data, source: path, access: access)
        built = Entry(asset: memory.asset, memory: memory, cost: data.count)
      } else {
        built = nil
      }
    } else {
      built = Entry(asset: AVURLAsset(url: path, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
    }

    lock.lock()
    if loading[key] === pending { loading.removeValue(forKey: key) }
    let current = ticket == generation && VaultMediaAccess.isCurrent(access, for: path)
    if current, let built, built.cost <= byteLimit {
      // Live segments get a fresh asset after each write; retain only the latest version.
      entries = entries.filter { $0.key.path != path }
      while !entries.isEmpty && (entries.count >= 8 || entries.values.reduce(0, { $0 + $1.entry.cost }) + built.cost > byteLimit) {
        if let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { entries.removeValue(forKey: oldest) }
      }
      clock &+= 1
      entries[key] = Cached(entry: built, used: clock)
    }
    pending.entry = current ? built : nil
    lock.unlock()
    pending.group.leave()
    if !current { built?.invalidate(); return nil }
    return built
  }
}
