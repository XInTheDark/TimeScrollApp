import Foundation

/// Writes a capture about 50 times a second on a queue shared with other work, like the app's writer
/// queue, and records how long each write took from asking to finishing.
final class SnapshotRangeCaptureLoad: @unchecked Sendable {
  let writer = DispatchQueue(label: "TimeScroll.Benchmark.Writer")
  private let database: SnapshotRangeTestDatabase
  private let lock = NSLock()
  private let finished = DispatchSemaphore(value: 0)
  private var waits: [Double] = []
  private(set) var longestQueuedMs = 0.0
  private(set) var longestOwnMs = 0.0
  private var isStopped = false
  private var timeMs: Int64

  init(database: SnapshotRangeTestDatabase, firstTimeMs: Int64) {
    self.database = database
    timeMs = firstTimeMs
  }

  func start() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      while !stopped {
        let began = DispatchTime.now().uptimeNanoseconds
        var entered: UInt64 = 0
        var left: UInt64 = 0
        writer.sync {
          entered = DispatchTime.now().uptimeNanoseconds
          database.addSnapshot(at: timeMs)
          timeMs += 5_000
          left = DispatchTime.now().uptimeNanoseconds
        }
        let wait = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        let queued = Double(entered - began) / 1e6
        let own = Double(left - entered) / 1e6
        lock.withLock {
          waits.append(wait)
          longestQueuedMs = max(longestQueuedMs, queued)
          longestOwnMs = max(longestOwnMs, own)
        }
        Thread.sleep(forTimeInterval: 0.02)
      }
      finished.signal()
    }
  }

  func stop() -> [Double] {
    lock.withLock { isStopped = true }
    finished.wait()
    return lock.withLock { waits }
  }

  private var stopped: Bool { lock.withLock { isStopped } }
}
