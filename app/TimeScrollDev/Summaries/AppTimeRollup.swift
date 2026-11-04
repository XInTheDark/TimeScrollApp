import Foundation

/// Turns time-ordered screen captures into per-bucket app time. A capture's whole dwell goes to the
/// bucket it starts in. Captures from all displays form one stream, so dwell never double counts.
enum AppTimeRollup {
  /// A mismatch with a stored day means the day is rebuilt.
  static let version = 1
  static let quarterHourMs: Int64 = 15 * 60_000
  static let maxAppsPerBucket = 100

  struct Day: Equatable {
    let quarterHours: [AppTimeRow]
    let day: [AppTimeRow]
  }

  static func day(captures: [AppTimeCapture], nextCaptureMs: Int64?, dayStartMs: Int64) -> Day {
    Day(quarterHours: rows(captures: captures, nextCaptureMs: nextCaptureMs, bucketMs: quarterHourMs),
        day: rows(captures: captures, nextCaptureMs: nextCaptureMs, limit: maxAppsPerBucket) { _ in dayStartMs })
  }

  static func rows(captures: [AppTimeCapture], nextCaptureMs: Int64?, bucketMs: Int64,
                   limit: Int = maxAppsPerBucket) -> [AppTimeRow] {
    rows(captures: captures, nextCaptureMs: nextCaptureMs, limit: limit) { floor($0, to: bucketMs) }
  }

  static func floor(_ timeMs: Int64, to bucketMs: Int64) -> Int64 {
    let remainder = timeMs % bucketMs
    return remainder >= 0 ? timeMs - remainder : timeMs - remainder - bucketMs
  }

  static func ceil(_ timeMs: Int64, to bucketMs: Int64) -> Int64 {
    let floored = floor(timeMs, to: bucketMs)
    return floored == timeMs ? timeMs : floored + bucketMs
  }

  private static func rows(captures: [AppTimeCapture], nextCaptureMs: Int64?, limit: Int,
                           bucket: (Int64) -> Int64) -> [AppTimeRow] {
    var result: [AppTimeRow] = []
    var current: [String: (dwellMs: Int64, count: Int64)] = [:]
    var currentBucket: Int64?

    for (index, capture) in captures.enumerated() {
      let bucketStart = bucket(capture.timeMs)
      if let open = currentBucket, open != bucketStart {
        flush(current, bucketMs: open, limit: limit, into: &result)
        current.removeAll(keepingCapacity: true)
      }
      currentBucket = bucketStart
      let next = index + 1 < captures.count ? captures[index + 1].timeMs : nextCaptureMs
      let dwell = CaptureDwell.ms(gapToNextMs: next.map { $0 - capture.timeMs } ?? 0)
      let entry = current[capture.app] ?? (0, 0)
      current[capture.app] = (entry.dwellMs + dwell, entry.count + 1)
    }
    if let open = currentBucket { flush(current, bucketMs: open, limit: limit, into: &result) }
    return result
  }

  /// Keeps the bucket's largest apps; the rest fold into "other" so its total stays exact.
  private static func flush(_ apps: [String: (dwellMs: Int64, count: Int64)], bucketMs: Int64, limit: Int,
                            into result: inout [AppTimeRow]) {
    let sorted = apps.sorted { $0.value.dwellMs != $1.value.dwellMs ? $0.value.dwellMs > $1.value.dwellMs : $0.key < $1.key }
    for (app, value) in sorted.prefix(limit) {
      result.append(AppTimeRow(bucketMs: bucketMs, app: app, dwellMs: value.dwellMs, snapshotCount: value.count))
    }
    guard sorted.count > limit else { return }
    var other = AppTimeRow(bucketMs: bucketMs, app: AppTimeRow.otherApp, dwellMs: 0, snapshotCount: 0)
    for (_, value) in sorted.dropFirst(limit) {
      other.dwellMs += value.dwellMs
      other.snapshotCount += value.count
    }
    result.append(other)
  }
}
