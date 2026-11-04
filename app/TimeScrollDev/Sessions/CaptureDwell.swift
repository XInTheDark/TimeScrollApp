import Foundation

/// How long a screen capture counts toward its app: until the next capture, capped. A capture before
/// an idle gap, or with nothing after it, counts for a short fixed time.
enum CaptureDwell {
  static let hardBreakMs: Int64 = 15 * 60_000
  static let capMs: Int64 = 60_000
  static let isolatedMs: Int64 = 5_000

  static func ms(gapToNextMs gap: Int64, hardBreakMs: Int64 = CaptureDwell.hardBreakMs, capMs: Int64 = CaptureDwell.capMs) -> Int64 {
    let dwell = gap > hardBreakMs || gap <= 0 ? min(isolatedMs, capMs) : min(gap, capMs)
    return max(1, dwell)
  }
}
