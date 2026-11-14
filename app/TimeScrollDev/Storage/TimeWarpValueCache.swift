import Foundation

/// Ids of stored Time Warp strings, so repeated URLs and titles cost no lookup. It belongs to one
/// connection: `DB.close()` clears it, because a new connection can reuse the old handle's address,
/// and a different handle starts empty too. Anything that deletes strings clears it. Locked, since
/// `close()` may run off the writer queue.
final class TimeWarpValueCache: @unchecked Sendable {
  private struct Key: Hashable {
    let domain: TimeWarpValueDomain
    let value: String
  }

  static let maxEntries = 4_096

  private let lock = NSLock()
  private var ids: [Key: Int64] = [:]
  private var owner: OpaquePointer?

  func id(domain: TimeWarpValueDomain, value: String, db: OpaquePointer) -> Int64? {
    lock.lock()
    defer { lock.unlock() }
    if owner != db {
      ids.removeAll()
      owner = db
    }
    return ids[Key(domain: domain, value: value)]
  }

  func store(_ id: Int64, domain: TimeWarpValueDomain, value: String) {
    lock.lock()
    defer { lock.unlock() }
    // Bounded: a long day of browsing must not grow memory without limit.
    if ids.count >= Self.maxEntries { ids.removeAll(keepingCapacity: true) }
    ids[Key(domain: domain, value: value)] = id
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    ids.removeAll()
    owner = nil
  }
}
