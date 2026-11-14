import Foundation

/// The text a Time Warp row shows. Pure, so it can be tested.
struct TimeWarpItemText: Equatable {
  let title: String
  let subtitle: String?
  let detail: String?
  /// For a moment's Time Warp: how long before the moment it was last in front.
  let recency: String?
  let help: String

  init(item: TimeWarpPlanItem, momentMs: Int64? = nil, appName: (String) -> String? = { _ in nil },
       homeDirectory: String = NSHomeDirectory(), timeText: (Int64) -> String = TimeWarpItemText.time) {
    switch item.kind {
    case .page:
      let link = TimeWarpLink.displayText(item.value)
      title = item.title ?? link
      subtitle = link
    case .document, .folder:
      let name = (item.value as NSString).lastPathComponent
      title = item.kind == .document ? (item.title ?? name) : name
      subtitle = Self.abbreviated((item.value as NSString).deletingLastPathComponent, home: homeDirectory)
    case .app:
      title = appName(item.value) ?? item.value
      subtitle = nil
    case .warpPoint:
      title = item.value.isEmpty ? "Warp point" : item.value
      subtitle = nil
    }

    if item.frontMs > 0 {
      let duration = TimelineRangeFormat.duration(item.frontMs)
      detail = duration
      let visits = item.visits > 1 ? " over \(item.visits) visits" : ""
      help = "In front for \(duration)\(visits)" + (item.wasOpenAtEnd ? ", still open at the end" : "")
    } else if item.wasOpenAtEnd {
      detail = "Open"
      help = "Open at the end of this time"
    } else {
      detail = nil
      help = title
    }
    recency = momentMs.flatMap { Self.recency(item, momentMs: $0) }
  }

  /// "At this moment" for what was in front then, "5m before" for what was in front earlier.
  static func recency(_ item: TimeWarpPlanItem, momentMs: Int64) -> String? {
    guard item.frontMs > 0 else { return nil }
    let before = momentMs - min(item.lastSeenMs, momentMs)
    if item.wasFrontAtMoment && before < 1_000 { return "At this moment" }
    return before < 60_000 ? "Just before" : "\(TimelineRangeFormat.duration(before)) before"
  }

  /// "~/Documents/Notes" for paths in the home folder.
  static func abbreviated(_ path: String, home: String) -> String {
    guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  static func time(_ ms: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
  }
}
