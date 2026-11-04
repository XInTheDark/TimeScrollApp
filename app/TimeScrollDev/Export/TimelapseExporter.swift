import Foundation
import CoreGraphics

enum TimelapseExporter {
  /// Call from a detached task. No capture work, database writes or timers are added while idle.
  static func export(options: TimelapseOptions, destination: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> TimelapseExportResult {
    guard options.end > options.start, options.speed.isFinite, options.speed >= 1 else { throw TimelapseError.invalidRange }
    let accessURL = StoragePaths.currentRoot()
    guard let access = VaultMediaAccess.token(for: accessURL) else { throw TimelapseError.locked }
    func check() throws {
      try Task.checkCancellation()
      guard VaultMediaAccess.isCurrent(access, for: accessURL) else { throw TimelapseError.locked }
    }
    try check()
    let endMs = min(options.endMs, Int64(Date().timeIntervalSince1970 * 1000))
    let summary = try DB.shared.timelapseSummary(fromMs: options.startMs, toMs: endMs)
    guard summary.count > 0 else { throw TimelapseError.empty }

    // UsageTracker records capture start/stop, independently of activity grouping and deduplication.
    let bounds = options.matchRealTime
      ? try DB.shared.timelapseRecordingIntervals(fromMs: options.startMs, toMs: endMs) : []
    var timing = TimelapseTiming(sessions: bounds, matchRealTime: options.matchRealTime, speed: options.speed)
    var page: [TimelapseFrame] = []
    var pageIndex = 0
    var cursor: TimelapseFrame?
    func nextFrame() throws -> TimelapseFrame? {
      try check()
      if pageIndex == page.count {
        page = try DB.shared.timelapseFrames(fromMs: options.startMs, toMs: endMs, throughID: summary.maxID, after: cursor)
        pageIndex = 0
      }
      guard pageIndex < page.count else { return nil }
      let frame = page[pageIndex]
      pageIndex += 1
      cursor = frame
      return frame
    }
    let maxPixel: CGFloat? = options.quality == .original ? nil : (options.quality == .fullHD ? 1920 : 1280)
    let loader = TimelapseImageLoader(maxPixel: maxPixel)
    var result = TimelapseExportResult()
    var processed = 0
    func nextReadable() async throws -> (frame: TimelapseFrame, image: CGImage)? {
      while let frame = try nextFrame() {
        let loaded = try await loader.load(frame, check: check)
        processed += 1
        if processed % 25 == 0 || processed == summary.count { progress(Double(processed) / Double(summary.count)) }
        if let loaded {
          if loaded.usedPreview { result.previews += 1 }
          return (frame, loaded.image)
        }
        result.skipped += 1
      }
      return nil
    }
    guard var current = try await nextReadable() else { throw TimelapseError.unreadable(options.startMs) }
    let size = options.quality.size(width: max(summary.width, current.image.width), height: max(summary.height, current.image.height))
    let output = TimelapseOutputFile(destination: destination)
    defer { output.discard() }
    let writer = try TimelapseVideoWriter(url: output.temporary, size: size)
    do {
      while true {
        try check()
        let next = try await nextReadable()
        try await writer.append(image: current.image, frame: current.frame, at: timing.seconds, timestamp: options.timestamp, check: check)
        timing.advance(from: current.frame.timeMs, to: next?.frame.timeMs)
        guard let next else { break }
        current = next
      }
      try check()
      try await writer.finish(at: timing.seconds)
      try output.publish(check: check)
      progress(1)
      return result
    } catch {
      writer.cancel()
      throw error
    }
  }
}
