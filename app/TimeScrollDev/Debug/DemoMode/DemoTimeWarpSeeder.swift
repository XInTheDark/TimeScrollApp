#if DEBUG
import Foundation

/// Stores the Time Warp history for the fake captures: the app and page or document in front for
/// each run of captures, and the manifest's Warp points. Documents are created as empty files in
/// the fake home, so the Time Warp window doesn't mark them missing.
enum DemoTimeWarpSeeder {
  static func seed(manifest: DemoManifest, captures: [DemoSchedule.Capture], now: Date) throws {
    let home = NSHomeDirectory()
    try createDocuments(manifest: manifest, home: home)
    let spans = DemoTimeWarpSpans.spans(of: captures, intervalSeconds: manifest.captureIntervalSeconds)
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    let points = (manifest.warpPoints ?? []).map { point in
      TimeWarpSpanStart(item: TimeWarpItem(kind: .warpPoint, value: point.note), source: .event,
                        appBundleId: nil, startMs: nowMs - Int64(point.minutesAgo) * 60_000)
    }
    try DB.shared.onQueueSync {
      try DB.shared.openIfNeeded()
      guard let db = DB.shared.db else { return }
      for span in spans {
        guard let screen = manifest.screens[span.screen] else { continue }
        var items = [TimeWarpItem(kind: .app, value: screen.bundleId)]
        if let context = screen.context, let item = item(for: context, home: home) { items.append(item) }
        for item in items {
          let start = TimeWarpSpanStart(item: item, source: .front, appBundleId: screen.bundleId, startMs: span.startMs)
          _ = DB.timeWarpInsert(start, endMs: span.endMs, isOpen: false, db: db, cache: DB.timeWarpValueCache)
        }
      }
      for point in points {
        _ = DB.timeWarpInsert(point, endMs: point.startMs, isOpen: false, db: db, cache: DB.timeWarpValueCache)
      }
    }
  }

  private static func item(for context: DemoManifest.Context, home: String) -> TimeWarpItem? {
    switch context.kind {
    case "page": return TimeWarpItem(kind: .page, value: context.value, title: context.title)
    case "document": return TimeWarpItem(kind: .document, value: expand(context.value, home: home), title: context.title)
    default: return nil
    }
  }

  private static func createDocuments(manifest: DemoManifest, home: String) throws {
    for screen in manifest.screens.values {
      guard let context = screen.context, context.kind == "document" else { continue }
      let url = URL(fileURLWithPath: expand(context.value, home: home))
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: url.path) {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
      }
    }
  }

  private static func expand(_ path: String, home: String) -> String {
    path.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(path.dropFirst(2))) : path
  }
}
#endif
