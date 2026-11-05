import Foundation

/// A time range selectable on the Stats pane's slider.
struct StatsWindow: Equatable, Sendable {
  let label: String
  /// Length of the range ending now. `nil` means all time.
  let seconds: TimeInterval?

  static let all: [StatsWindow] = [
    StatsWindow(label: "All time", seconds: nil),
    StatsWindow(label: "1h", seconds: 3600),
    StatsWindow(label: "6h", seconds: 6 * 3600),
    StatsWindow(label: "24h", seconds: 24 * 3600),
    StatsWindow(label: "7d", seconds: 7 * 24 * 3600),
    StatsWindow(label: "30d", seconds: 30 * 24 * 3600),
    StatsWindow(label: "90d", seconds: 90 * 24 * 3600),
    StatsWindow(label: "1y", seconds: 365 * 24 * 3600),
  ]

  var isAllTime: Bool { seconds == nil }

  func cutoffSeconds(now: TimeInterval) -> TimeInterval? {
    seconds.map { now - $0 }
  }

  func cutoffMs(now: TimeInterval) -> Int64? {
    cutoffSeconds(now: now).map { Int64($0 * 1000) }
  }
}
