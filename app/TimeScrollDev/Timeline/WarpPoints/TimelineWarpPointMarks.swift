import AppKit

/// Warp point markers on the timeline: a small pin head above the rows and a faint line through
/// them. Positions are cached per layout; drawing touches only the markers in view.
struct TimelineWarpPointMarks {
  static let headRadius: CGFloat = 4
  static let headCenterY: CGFloat = 6
  /// Clicks this close to a head hit it.
  static let hitSlop: CGFloat = 4

  /// Marker x positions, ascending, with the points they stand for.
  let xs: [CGFloat]
  let points: [TimeWarpPointNote]

  init(points: [TimeWarpPointNote], x: (Int64) -> CGFloat) {
    let placed = points.map { (x($0.timeMs), $0) }.sorted { $0.0 < $1.0 }
    xs = placed.map(\.0)
    self.points = placed.map(\.1)
  }

  static let empty = TimelineWarpPointMarks(points: [], x: { _ in 0 })

  /// Indices of markers whose heads fall within `minX...maxX`.
  func indices(from minX: CGFloat, to maxX: CGFloat) -> Range<Int> {
    let lower = Self.firstIndex(in: xs, atOrAfter: minX - Self.headRadius)
    let upper = Self.firstIndex(in: xs, atOrAfter: maxX + Self.headRadius + .ulpOfOne)
    return lower..<max(lower, upper)
  }

  /// The marker whose head is under `point`, the nearest when heads overlap.
  func hit(_ point: NSPoint) -> TimeWarpPointNote? {
    let reach = Self.headRadius + Self.hitSlop
    guard abs(point.y - Self.headCenterY) <= reach else { return nil }
    let range = indices(from: point.x - reach, to: point.x + reach)
    return range.min { abs(xs[$0] - point.x) < abs(xs[$1] - point.x) }.map { points[$0] }
  }

  func headRect(at index: Int) -> NSRect {
    let r = Self.headRadius + Self.hitSlop
    return NSRect(x: xs[index] - r, y: Self.headCenterY - r, width: r * 2, height: r * 2)
  }

  /// Draws the markers in `visible`, with lines from the heads down to `linesTo`.
  func draw(in visible: NSRect, linesTo bottomY: CGFloat) {
    let range = indices(from: visible.minX, to: visible.maxX)
    guard !range.isEmpty else { return }
    let color = NSColor.systemTeal
    let line = NSBezierPath()
    for index in range {
      line.move(to: NSPoint(x: xs[index], y: Self.headCenterY + Self.headRadius))
      line.line(to: NSPoint(x: xs[index], y: bottomY))
    }
    line.lineWidth = 1
    color.withAlphaComponent(0.45).setStroke()
    line.stroke()
    for index in range {
      let r = Self.headRadius
      let head = NSBezierPath(ovalIn: NSRect(x: xs[index] - r, y: Self.headCenterY - r, width: r * 2, height: r * 2))
      color.setFill()
      head.fill()
      NSColor.windowBackgroundColor.setStroke()
      head.lineWidth = 1.5
      head.stroke()
    }
  }

  static func firstIndex(in values: [CGFloat], atOrAfter target: CGFloat) -> Int {
    var low = 0
    var high = values.count
    while low < high {
      let mid = (low + high) / 2
      if values[mid] < target { low = mid + 1 } else { high = mid }
    }
    return low
  }
}
