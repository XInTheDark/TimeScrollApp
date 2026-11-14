#if DEBUG
import Foundation

/// The curated fake history, read from `scripts/marketing/data/manifest.json`.
struct DemoManifest: Decodable {
  struct Screen: Decodable {
    let app: String
    let bundleId: String
    /// The page or document Time Warp records while this screen is in front.
    let context: Context?
  }

  /// A Time Warp item. Document paths starting with `~/` are inside the fake home.
  struct Context: Decodable {
    /// "page" or "document".
    let kind: String
    let value: String
    let title: String
  }

  struct WarpPoint: Decodable {
    let minutesAgo: Int
    let note: String
  }

  struct Block: Decodable, Equatable {
    /// "HH:mm" local time.
    let start: String
    let minutes: Int
    let screen: String
  }

  struct Summary: Decodable {
    /// "yesterday" or "lastWeek".
    let range: String
    let text: String
  }

  /// A meeting recorded from system audio, with a transcript line every 20 seconds.
  struct Recording: Decodable {
    let minutesAgo: Int
    let lines: [String]
  }

  let screens: [String: Screen]
  /// Working days, cycled over past weekdays.
  let days: [[Block]]
  /// Today's blocks, ending now.
  let today: [Block]
  let summaries: [Summary]
  let recording: Recording
  let warpPoints: [WarpPoint]?
  let excludedBundleIds: [String]
  let historyDays: Int
  let captureIntervalSeconds: Int
}
#endif
