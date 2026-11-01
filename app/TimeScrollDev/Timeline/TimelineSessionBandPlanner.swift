import CoreGraphics

/// One session drawn on the timeline's session band.
struct TimelineSessionBand: Equatable {
  let x0: CGFloat
  let x1: CGFloat
  /// Index into the sessions the band was planned from.
  let sessionIndex: Int
  /// The label fitted to the band's width, or nil when even a short one does not fit.
  let label: String?
  /// Right edge when drawn: past `x1` for the head of a run of narrow bands, which are drawn as one.
  let drawX1: CGFloat
  /// First and last band of the run this band is drawn in; both are the band's own index when alone.
  let runHead: Int
  let runLast: Int

  init(x0: CGFloat, x1: CGFloat, sessionIndex: Int, label: String?, drawX1: CGFloat? = nil, runHead: Int? = nil, runLast: Int? = nil) {
    self.x0 = x0
    self.x1 = x1
    self.sessionIndex = sessionIndex
    self.label = label
    self.drawX1 = drawX1 ?? x1
    self.runHead = runHead ?? sessionIndex
    self.runLast = runLast ?? sessionIndex
  }

  var width: CGFloat { x1 - x0 }
  /// Drawn as part of the run's head, not on its own.
  var isRunTail: Bool { runHead != sessionIndex }
}

/// Lays out session bands once per layout (positions and fitted labels), so drawing only walks the
/// visible slice. Like screen blocks, on the compressed axis a band runs up to the next one.
enum TimelineSessionBandPlanner {
  static let gutter: CGFloat = 2
  static let minWidth: CGFloat = 3
  static let labelPadding: CGFloat = 6
  static let minLabelWidth: CGFloat = 28
  /// Bands narrower than this, side by side, are drawn as one: a burst of short sessions would
  /// otherwise be a row of tiny rounded stubs.
  static let runWidth: CGFloat = 20

  /// `sessions` must be sorted by start. `labelWidth` measures a label as drawn.
  static func plan(sessions: [ActivitySession], x: (Int64) -> CGFloat, fillsGaps: Bool,
                   labelWidth: (String) -> CGFloat) -> [TimelineSessionBand] {
    let starts = sessions.map { x($0.startMs) }
    var bands: [TimelineSessionBand] = []
    bands.reserveCapacity(sessions.count)
    for (index, session) in sessions.enumerated() {
      let x0 = starts[index]
      let hasNext = index + 1 < sessions.count
      let nextX0 = hasNext ? starts[index + 1] : .greatestFiniteMagnitude
      var end = max(x(session.endMs), x0 + minWidth)
      if fillsGaps && hasNext { end = max(end, nextX0) }
      let x1 = nextX0 - gutter - x0 >= minWidth ? min(end, nextX0 - gutter) : max(x0 + 1, min(end, nextX0))
      bands.append(TimelineSessionBand(x0: x0, x1: x1, sessionIndex: index,
                                       label: fittedLabel(for: session, width: x1 - x0 - 2 * labelPadding, labelWidth: labelWidth)))
    }
    return merged(bands)
  }

  /// Marks runs of consecutive narrow bands (see `runWidth`) so they draw as a single block.
  static func merged(_ bands: [TimelineSessionBand]) -> [TimelineSessionBand] {
    var result = bands
    var head = 0
    while head < bands.count {
      var last = head
      if bands[head].width < runWidth {
        while last + 1 < bands.count, bands[last + 1].width < runWidth, bands[last + 1].x0 - bands[last].x1 <= runWidth { last += 1 }
      }
      if last > head {
        for index in head...last {
          let band = bands[index]
          result[index] = TimelineSessionBand(x0: band.x0, x1: band.x1, sessionIndex: index, label: nil,
                                              drawX1: index == head ? bands[last].x1 : band.x1, runHead: head, runLast: last)
        }
      }
      head = last + 1
    }
    return result
  }

  /// The title, else the title cut short with an ellipsis.
  static func fittedLabel(for session: ActivitySession, width: CGFloat, labelWidth: (String) -> CGFloat) -> String? {
    guard width >= minLabelWidth else { return nil }
    let title = session.title
    if labelWidth(title) <= width { return title }
    let characters = Array(title)
    var low = 0
    var high = characters.count
    while low < high {
      let mid = (low + high + 1) / 2
      if labelWidth(String(characters.prefix(mid)) + "…") <= width { low = mid } else { high = mid - 1 }
    }
    return low > 0 ? String(characters.prefix(low)) + "…" : nil
  }

  /// Index of the first band ending at or right of `x`; band ends rise with their starts.
  static func firstIndex(endingAtOrAfter x: CGFloat, in bands: [TimelineSessionBand]) -> Int {
    var low = 0
    var high = bands.count
    while low < high {
      let mid = (low + high) / 2
      if bands[mid].x1 < x { low = mid + 1 } else { high = mid }
    }
    return low
  }

  /// Index of the session spanning `timeMs` (start to last capture), if any. `sessions` sorted by start.
  static func sessionIndex(containing timeMs: Int64, in sessions: [ActivitySession]) -> Int? {
    var low = 0
    var high = sessions.count
    while low < high {
      let mid = (low + high) / 2
      if sessions[mid].startMs <= timeMs { low = mid + 1 } else { high = mid }
    }
    guard low > 0, timeMs <= sessions[low - 1].endMs else { return nil }
    return low - 1
  }

  /// The band under `x`, if any.
  static func band(at x: CGFloat, in bands: [TimelineSessionBand]) -> TimelineSessionBand? {
    let index = firstIndex(endingAtOrAfter: x, in: bands)
    guard index < bands.count else { return nil }
    if bands[index].x0 <= x { return bands[index] }
    // The gutters inside a run are part of the block drawn there.
    if index > 0, bands[index].runHead == bands[index - 1].runHead, bands[index].isRunTail { return bands[index - 1] }
    return nil
  }
}
