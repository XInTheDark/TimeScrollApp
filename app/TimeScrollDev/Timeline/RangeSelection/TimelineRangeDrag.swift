import CoreGraphics
import Foundation

/// One drag on the timeline while selecting. Pressing near an edge of the current range moves that
/// edge; pressing anywhere else starts a new range. Pure, so it is tested without a view.
struct TimelineRangeDrag: Equatable {
  static let edgeTolerance: CGFloat = 6
  /// Movement below this is a click.
  static let clickSlop: CGFloat = 3

  private let anchorMs: Int64
  private let startX: CGFloat
  private let startsOnEdge: Bool
  private(set) var moved = false

  init(x: CGFloat, timeMs: Int64, current: TimelineRange?, lowerX: CGFloat?, upperX: CGFloat?) {
    startX = x
    if let current, let upperX, abs(x - upperX) <= Self.edgeTolerance {
      // `covering` includes the time it is given, so this keeps the edge that stays put exact.
      anchorMs = current.fromMs
      startsOnEdge = true
    } else if let current, let lowerX, abs(x - lowerX) <= Self.edgeTolerance {
      anchorMs = current.toMs - 1
      startsOnEdge = true
    } else {
      anchorMs = timeMs
      startsOnEdge = false
    }
  }

  /// The range to show for the cursor at `x`, or nil while it is still a click.
  mutating func update(x: CGFloat, timeMs: Int64) -> TimelineRange? {
    if !moved, abs(x - startX) < Self.clickSlop { return nil }
    moved = true
    return TimelineRange.covering(anchorMs, timeMs)
  }

  /// Whether a press at `x` would grab an edge.
  static func isOnEdge(x: CGFloat, lowerX: CGFloat?, upperX: CGFloat?) -> Bool {
    [lowerX, upperX].contains { $0.map { abs(x - $0) <= edgeTolerance } ?? false }
  }
}
