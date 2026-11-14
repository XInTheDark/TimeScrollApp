import Foundation

/// What a Time Warp is for: a block of time the user picked, or a single moment. A moment is a
/// shortcut for the block that ends at it, with a look-back the user can change.
enum TimeWarpTarget: Equatable, Sendable {
  case range(TimelineRange)
  case moment(Int64)

  var momentMs: Int64? {
    if case let .moment(ms) = self { return ms }
    return nil
  }
}
