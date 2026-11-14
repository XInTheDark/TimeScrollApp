import Foundation

/// Ranks what was in front by how close it was to a moment: each millisecond in front counts half
/// as much for every `halfLifeMs` it lies before the moment. Pure, so it can be tested.
enum TimeWarpRecency {
  static let halfLifeMs: Double = 15 * 60_000

  /// Weighted time in front for `[startMs, endMs)`, with time after the moment ignored.
  static func weightedMs(startMs: Int64, endMs: Int64, momentMs: Int64, halfLifeMs: Double = halfLifeMs) -> Double {
    let end = min(endMs, momentMs)
    guard end > startMs, halfLifeMs > 0 else { return 0 }
    // The integral of 2^(-(moment - t) / halfLife) over [start, end].
    func decay(_ ms: Int64) -> Double { exp2(-Double(momentMs - ms) / halfLifeMs) }
    return halfLifeMs / M_LN2 * (decay(end) - decay(startMs))
  }
}
