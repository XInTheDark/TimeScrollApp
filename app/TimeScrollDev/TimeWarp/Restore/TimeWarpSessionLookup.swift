import Foundation

/// Finds the start of the activity session a moment is in, for the "This Session" look-back.
/// Blocks on the session provider; call off the main thread.
enum TimeWarpSessionLookup {
  /// A moment just after a session's last snapshot still belongs to it: the screen stayed the same.
  static let toleranceMs: Int64 = 5 * 60_000

  static func sessionStart(containing momentMs: Int64) -> Int64? {
    let sensitivity = SessionSensitivity.stored()
    guard let sessions = ActivitySessionProvider.shared.sessions(coveringTimes: [momentMs], sensitivity: sensitivity) else { return nil }
    return start(containing: momentMs, in: sessions)
  }

  /// The latest session that contains the moment, allowing `toleranceMs` after its end. Pure.
  static func start(containing momentMs: Int64, in sessions: [ActivitySession]) -> Int64? {
    sessions
      .filter { $0.startMs <= momentMs && momentMs <= $0.endMs + toleranceMs }
      .map(\.startMs)
      .max()
  }
}
