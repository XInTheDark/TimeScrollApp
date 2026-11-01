import CoreGraphics
import Foundation

/// What the timeline's hover preview shows about a session: when it ran, how long, and where the
/// time went. Pure data and layout math, so the view stays a plain renderer.
struct SessionHoverContent: Equatable {
  struct AppRow: Equatable {
    let bundleId: String?
    let name: String
    /// Share of the listed apps' time, 0...1.
    let fraction: Double
    let durationText: String
  }

  static let width: CGFloat = 260
  static let headerHeight: CGFloat = 28
  static let rowHeight: CGFloat = 18
  static let keywordsHeight: CGFloat = 30
  static let spacing: CGFloat = 6

  let rangeText: String
  let summaryText: String
  let rows: [AppRow]
  let keywordsText: String?

  /// Height of the session section below the thumbnail's own rows; every part has a fixed height so
  /// the popover can be sized before the view lays out.
  var height: CGFloat {
    var total = Self.headerHeight + Self.spacing + CGFloat(rows.count) * Self.rowHeight
    if keywordsText != nil { total += Self.spacing + Self.keywordsHeight }
    return total
  }

  init(session: ActivitySession) {
    let start = Date(timeIntervalSince1970: TimeInterval(session.startMs) / 1000)
    let end = Date(timeIntervalSince1970: TimeInterval(session.endMs) / 1000)
    let interval = DateIntervalFormatter()
    interval.dateStyle = .none
    interval.timeStyle = .short
    rangeText = session.durationMs < 60_000 ? interval.string(from: start, to: start) : interval.string(from: start, to: end)

    let snapshots = session.snapshotCount == 1 ? "1 snapshot" : "\(session.snapshotCount) snapshots"
    summaryText = "\(Self.durationText(ms: session.durationMs)) · \(snapshots)"

    let total = max(1, session.apps.reduce(Int64(0)) { $0 + $1.ms })
    rows = session.apps.map {
      AppRow(bundleId: $0.bundleId, name: $0.name ?? $0.bundleId ?? "Unknown",
             fraction: min(1, Double($0.ms) / Double(total)), durationText: Self.durationText(ms: $0.ms))
    }
    keywordsText = session.keywords.isEmpty ? nil : session.keywords.joined(separator: ", ")
  }

  static func durationText(ms: Int64) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = ms >= 60_000 ? [.hour, .minute] : [.second]
    formatter.zeroFormattingBehavior = .dropAll
    return formatter.string(from: TimeInterval(max(0, ms)) / 1000) ?? ""
  }
}
