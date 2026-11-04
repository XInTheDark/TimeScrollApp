import Foundation

/// Time spent in one app within one time bucket.
struct AppTimeRow: Equatable {
  /// Folded remainder of a bucket that held more apps than the limit.
  static let otherApp = "\u{1}other"
  /// Captures with neither a bundle id nor an app name.
  static let unknownApp = ""

  let bucketMs: Int64
  /// Bundle id, or the app name when there is none.
  let app: String
  var dwellMs: Int64
  var snapshotCount: Int64
}

/// One screen capture reduced to what app time needs.
struct AppTimeCapture: Equatable {
  let timeMs: Int64
  let app: String
}

/// The bucket sizes stored in `ts_app_time`.
enum AppTimeSpan: Int32 {
  case quarterHour = 0
  case day = 1
}
