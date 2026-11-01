import Foundation

/// Sketches texts stored before sessions existed, newest first, in small batches on a background
/// queue with pauses between them, so capture writes and UI reads keep flowing. Days viewed before
/// it finishes sketch their own texts on demand.
final class SessionSketchBackfill: @unchecked Sendable {
  static let shared = SessionSketchBackfill()
  private init() {}

  private static let batchSize = 200
  private static let pauseBetweenBatches: TimeInterval = 0.25

  private let queue = DispatchQueue(label: "TimeScroll.SessionSketchBackfill", qos: .background)
  private let lock = NSLock()
  private var running = false

  func resumeIfNeeded() {
    lock.lock()
    guard !running else { lock.unlock(); return }
    running = true
    lock.unlock()

    queue.async { [self] in
      defer {
        lock.lock(); running = false; lock.unlock()
      }
      var cursor = Int64.max
      while true {
        // Stops on errors (e.g. vault locked); the next maintenance run resumes.
        guard let ids = try? DB.shared.backfillSessionSketchBatch(beforeId: cursor, limit: Self.batchSize),
              let lowest = ids.min() else { return }
        cursor = lowest
        Thread.sleep(forTimeInterval: Self.pauseBetweenBatches)
      }
    }
  }
}
