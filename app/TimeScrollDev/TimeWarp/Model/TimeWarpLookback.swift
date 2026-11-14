import Foundation

/// How far back a moment's Time Warp looks.
enum TimeWarpLookback: String, CaseIterable, Identifiable, Sendable {
  case fifteenMinutes
  case hour
  /// The activity session the moment is in, from its start.
  case session
  case today

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fifteenMinutes: return "15 Minutes"
    case .hour: return "1 Hour"
    case .session: return "This Session"
    case .today: return "Today"
    }
  }

  /// Used when the moment isn't in a session.
  static let sessionFallback: TimeWarpLookback = .hour

  /// The next longer look-back, if any.
  var longer: TimeWarpLookback? {
    switch self {
    case .fifteenMinutes: return .hour
    case .hour: return .session
    case .session: return .today
    case .today: return nil
    }
  }

  /// The look-back actually used: a session look-back without a session falls back.
  func effective(sessionStartMs: Int64?) -> TimeWarpLookback {
    self == .session && sessionStartMs == nil ? Self.sessionFallback : self
  }

  /// The block from the look-back's start to the moment, covering the moment's whole second.
  func range(endingAt momentMs: Int64, sessionStartMs: Int64?, calendar: Calendar = .current) -> TimelineRange {
    let start: Int64
    switch effective(sessionStartMs: sessionStartMs) {
    case .fifteenMinutes: start = momentMs - 15 * 60_000
    case .hour: start = momentMs - 60 * 60_000
    case .session: start = min(sessionStartMs ?? momentMs, momentMs)
    case .today:
      let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(momentMs) / 1000))
      start = Int64((day.timeIntervalSince1970 * 1000).rounded())
    }
    return TimelineRange.covering(start, momentMs)
  }
}
