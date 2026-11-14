import Foundation

/// When to read after a burst of notifications. A page load fires 6–9 title changes within 50 ms,
/// so reads wait for a quiet `delay`; a page whose title never stops changing still gets read once
/// `maxDelay` has passed since the burst began.
struct TimeWarpDebounce: Equatable {
  static let delay: TimeInterval = 0.5
  static let maxDelay: TimeInterval = 2

  private(set) var firstEventAt: TimeInterval?
  private(set) var lastEventAt: TimeInterval?

  /// Records an event and returns when the read is due.
  mutating func note(at time: TimeInterval) -> TimeInterval {
    if firstEventAt == nil { firstEventAt = time }
    lastEventAt = time
    return dueTime!
  }

  var dueTime: TimeInterval? {
    guard let firstEventAt, let lastEventAt else { return nil }
    return min(lastEventAt + Self.delay, firstEventAt + Self.maxDelay)
  }

  /// Whether the read is due at `time`; if so, the burst is over.
  mutating func fire(at time: TimeInterval) -> Bool {
    guard let due = dueTime, time >= due - 0.001 else { return false }
    firstEventAt = nil
    lastEventAt = nil
    return true
  }
}
