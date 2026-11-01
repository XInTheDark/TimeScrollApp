import CoreGraphics

/// One block drawn on the screen track: a run of captures from the same app.
struct TimelineScreenBlock: Equatable {
  let x0: CGFloat
  let x1: CGFloat
  let appBundleId: String?

  var width: CGFloat { x1 - x0 }
}

/// Turns screen segments into the blocks drawn on the timeline. Consecutive segments of the same app
/// merge, and on the compressed axis each block runs up to the next one: a snapshot shows the screen
/// until the next capture, since unchanged frames are dropped. Without this, the sparse captures of an
/// idle screen were drawn as rows of 1 pt stripes.
enum TimelineScreenBlockPlanner {
  struct Span {
    let x0: CGFloat
    let x1: CGFloat
    let appBundleId: String?
  }

  static let gutter: CGFloat = 2
  static let minWidth: CGFloat = 4

  /// `spans` must be sorted by `x0`. `fillsGaps` is true on the compressed axis.
  static func plan(spans: [Span], fillsGaps: Bool) -> [TimelineScreenBlock] {
    var runs: [Span] = []
    runs.reserveCapacity(spans.count)
    for span in spans {
      // On the linear axis only spans too close to show a gap between them merge.
      if let last = runs.last, last.appBundleId == span.appBundleId,
         fillsGaps || span.x0 - last.x1 < minWidth {
        runs[runs.count - 1] = Span(x0: last.x0, x1: max(last.x1, span.x1), appBundleId: last.appBundleId)
      } else {
        runs.append(span)
      }
    }

    var blocks: [TimelineScreenBlock] = []
    blocks.reserveCapacity(runs.count)
    for (index, run) in runs.enumerated() {
      let hasNext = index + 1 < runs.count
      let nextX0 = hasNext ? runs[index + 1].x0 : .greatestFiniteMagnitude
      let end = fillsGaps && hasNext ? max(run.x1, nextX0) : max(run.x1, run.x0 + minWidth)
      // Keep a gutter before the next block when this one stays wide enough; dense app switching
      // instead draws touching blocks, not stripes with dark gaps.
      let x1 = nextX0 - gutter - run.x0 >= minWidth
        ? min(end, nextX0 - gutter)
        : max(run.x0 + 1, min(end, nextX0))
      blocks.append(TimelineScreenBlock(x0: run.x0, x1: x1, appBundleId: run.appBundleId))
    }
    return blocks
  }

  /// Index of the first block ending at or right of `x`; block ends rise with their starts.
  static func firstIndex(endingAtOrAfter x: CGFloat, in blocks: [TimelineScreenBlock]) -> Int {
    var low = 0
    var high = blocks.count
    while low < high {
      let mid = (low + high) / 2
      if blocks[mid].x1 < x { low = mid + 1 } else { high = mid }
    }
    return low
  }
}
