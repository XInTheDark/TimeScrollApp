import Foundation

/// Keeps the Warp points for the timeline's loaded time range. Reloads when the range or the data
/// changes, a Warp point is added, or the markers are turned on; the query reads a tiny index.
@MainActor
final class TimelineWarpPointLoader: ObservableObject {
  @Published private(set) var points: [TimeWarpPointNote] = []
  /// Bumped whenever `points` changes, so drawing can cache marker positions cheaply.
  private(set) var revision: UInt64 = 0
  private var token = 0

  func refresh(fromMs: Int64, toMs: Int64, enabled: Bool) {
    token &+= 1
    guard enabled, toMs > fromMs, toMs > 0 else {
      publish([])
      return
    }
    let requestToken = token
    Task.detached(priority: .utility) {
      // Nil while the vault is locked: show none rather than stale markers.
      let loaded = (try? DB.shared.timeWarpPoints(fromMs: fromMs, toMs: toMs)) ?? []
      await MainActor.run { [weak self] in
        guard let self, requestToken == self.token else { return }
        self.publish(loaded)
      }
    }
  }

  private func publish(_ new: [TimeWarpPointNote]) {
    guard new != points else { return }
    points = new
    revision &+= 1
  }
}
