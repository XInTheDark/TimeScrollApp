import Foundation

/// Source time has a single scale across sessions; only time outside session bounds is removed.
struct TimelapseTiming {
  private let sessions: [ClosedRange<Int64>]
  private let speed: Double
  private let matchRealTime: Bool
  private var sessionIndex = 0
  private(set) var seconds = 0.0

  init(sessions: [ClosedRange<Int64>], matchRealTime: Bool, speed: Double) {
    self.sessions = sessions
    self.matchRealTime = matchRealTime
    self.speed = max(1, speed)
  }

  /// Frames arrive oldest first. Equal timestamps (e.g. several displays) remain visible in ID order.
  mutating func advance(from current: Int64, to next: Int64?) {
    guard matchRealTime else {
      seconds += 1.0 / 30
      return
    }
    while sessionIndex < sessions.count && sessions[sessionIndex].upperBound < current { sessionIndex += 1 }
    guard let next else {
      let end = sessionIndex < sessions.count ? sessions[sessionIndex].upperBound : current
      seconds += max(1.0 / 30, Double(max(0, end - current)) / 1000 / speed)
      return
    }
    // Older recordings without usage metadata retain their observed intervals rather than guessing pauses.
    if sessions.isEmpty {
      seconds += max(1.0 / 600, Double(max(0, next - current)) / 1000 / speed)
      return
    }
    var index = sessionIndex
    var activeMs: Int64 = 0
    while index < sessions.count && sessions[index].lowerBound <= next {
      activeMs += max(0, min(next, sessions[index].upperBound) - max(current, sessions[index].lowerBound))
      index += 1
    }
    // Retain a visible boundary frame without carrying a session's idle gap into the movie.
    seconds += max(1.0 / 600, Double(activeMs) / 1000 / speed)
  }
}
