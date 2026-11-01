import Foundation

/// Keeps the sessions for the timeline's loaded time range. Reloads only when the range, the
/// sensitivity or visibility changes; the provider serves unchanged days from its cache.
@MainActor
final class TimelineSessionLoader: ObservableObject {
  @Published private(set) var sessions: [ActivitySession] = []
  /// Bumped whenever `sessions` changes, so drawing can cache its band layout cheaply.
  private(set) var revision: UInt64 = 0
  private var token = 0

  func refresh(fromMs: Int64, toMs: Int64, sensitivity: SessionSensitivity, enabled: Bool) {
    token &+= 1
    guard enabled, toMs >= fromMs, toMs > 0 else {
      publish([])
      return
    }
    let requestToken = token
    ActivitySessionProvider.shared.sessions(fromMs: fromMs, toMs: toMs, sensitivity: sensitivity) { [weak self] result in
      guard let self, requestToken == self.token else { return }
      // Unavailable (vault locked): show none rather than stale sessions.
      self.publish(result ?? [])
    }
  }

  private func publish(_ new: [ActivitySession]) {
    guard new != sessions else { return }
    sessions = new
    revision &+= 1
  }
}
