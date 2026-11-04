import Foundation

/// Publishes a complete movie atomically; cancellation and failure leave an existing export intact.
struct TimelapseOutputFile {
  let destination: URL
  let temporary: URL

  init(destination: URL) {
    self.destination = destination
    temporary = destination.deletingLastPathComponent().appendingPathComponent(".timescroll-export-\(UUID().uuidString).mov")
  }

  func publish(check: () throws -> Void) throws {
    try check()
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
  }

  func discard() { try? FileManager.default.removeItem(at: temporary) }
}
