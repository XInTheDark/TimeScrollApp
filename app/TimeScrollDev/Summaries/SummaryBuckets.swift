import Foundation

/// Splits a long range into calendar periods that each get an equal share of the input, so later
/// periods can't be crowded out.
enum SummaryBuckets {
  /// Up to this long, raw session text fits and buckets aren't used.
  static let detailedLimitMs: Int64 = 48 * 60 * 60 * 1000
  private static let dayMs: Int64 = 24 * 60 * 60 * 1000

  static func unit(lengthMs: Int64) -> Calendar.Component {
    if lengthMs <= 14 * dayMs { return .day }
    if lengthMs <= 92 * dayMs { return .weekOfYear }
    if lengthMs <= 4 * 366 * dayMs { return .month }
    return .year
  }

  /// Oldest first, clipped to `[fromMs, toMs)`.
  static func buckets(fromMs: Int64, toMs: Int64, calendar: Calendar) -> [Range<Int64>] {
    guard toMs > fromMs else { return [] }
    let unit = unit(lengthMs: toMs - fromMs)
    var buckets: [Range<Int64>] = []
    var cursor = fromMs
    while cursor < toMs {
      let date = Date(timeIntervalSince1970: TimeInterval(cursor) / 1000)
      guard let interval = calendar.dateInterval(of: unit, for: date) else { break }
      let end = Int64((interval.end.timeIntervalSince1970 * 1000).rounded())
      guard end > cursor else { break }
      buckets.append(cursor..<min(end, toMs))
      cursor = end
    }
    if cursor < toMs { buckets.append(cursor..<toMs) }
    return buckets
  }
}
