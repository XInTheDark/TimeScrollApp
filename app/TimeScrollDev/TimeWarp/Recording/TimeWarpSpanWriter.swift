import Foundation

/// Carries the tracker's actions out against a store and reports the results back to it.
enum TimeWarpSpanWriter {
  static func apply(_ actions: [TimeWarpSpanTracker.Action], to tracker: inout TimeWarpSpanTracker,
                    store: TimeWarpSpanStore) {
    for action in actions {
      switch action {
      case let .open(slot, start):
        tracker.didOpen(slot, start: start, id: store.timeWarpOpenSpan(start))
      case let .close(ids, endMs):
        store.timeWarpCloseSpans(ids: ids, endMs: endMs)
      }
    }
  }
}
