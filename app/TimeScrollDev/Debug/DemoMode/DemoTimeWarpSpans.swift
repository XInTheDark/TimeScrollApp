#if DEBUG
import Foundation

/// Turns capture times into the Time Warp spans the recorder would have written: one per run of
/// captures of the same screen, ending one interval after its last capture. Pure, so it can be tested.
enum DemoTimeWarpSpans {
  struct Span: Equatable {
    let screen: String
    let startMs: Int64
    let endMs: Int64
  }

  static func spans(of captures: [DemoSchedule.Capture], intervalSeconds: Int) -> [Span] {
    let intervalMs = Int64(max(intervalSeconds, 0)) * 1000
    var spans: [Span] = []
    var current: (screen: String, startMs: Int64, lastMs: Int64)?
    for capture in captures {
      // A gap longer than one interval (overnight, lunch) ends the run even on the same screen.
      if let run = current, run.screen == capture.screen, capture.timeMs - run.lastMs <= intervalMs {
        current = (run.screen, run.startMs, capture.timeMs)
        continue
      }
      if let run = current { spans.append(Span(screen: run.screen, startMs: run.startMs, endMs: run.lastMs + intervalMs)) }
      current = (capture.screen, capture.timeMs, capture.timeMs)
    }
    if let run = current { spans.append(Span(screen: run.screen, startMs: run.startMs, endMs: run.lastMs + intervalMs)) }
    return spans
  }
}
#endif
