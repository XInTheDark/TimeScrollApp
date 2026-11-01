import CoreGraphics
import Foundation

struct TimelineTick: Equatable {
  let x: CGFloat
  let isMajor: Bool
  /// Text drawn under the tick, if it has room for one.
  let label: String?
  /// Day-change labels carry the date and are drawn bold.
  let emphasized: Bool
}

/// Plans the ticks and labels of the compressed timeline axis. Planning walks every snapshot, so it
/// is done once per layout and the view only draws the slice that is on screen.
enum TimelineTickPlanner {
  static let majorSpacing: CGFloat = 60
  static let minorSpacing: CGFloat = 22
  static let labelGap: CGFloat = 10

  /// Where a label centered on `x` starts; labels at the content edges are pulled fully inside.
  static func labelOriginX(centeredAt x: CGFloat, width: CGFloat, viewWidth: CGFloat) -> CGFloat {
    min(max(2, x - width / 2), viewWidth - width - 2)
  }

  /// `labelText` formats a time (with the date when `includesDay`); `labelWidth` measures it.
  static func plan(timesAsc: [Int64],
                   positionsAsc: [CGFloat],
                   viewWidth: CGFloat,
                   calendar: Calendar = .current,
                   labelText: (Int64, _ includesDay: Bool) -> String,
                   labelWidth: (String, _ emphasized: Bool) -> CGFloat) -> [TimelineTick] {
    var ticks: [TimelineTick] = []
    var lastMajorX = -CGFloat.greatestFiniteMagnitude
    var lastMinorX = -CGFloat.greatestFiniteMagnitude
    var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude
    var lastLabelText = ""
    // A day change is labelled with the date on the next major tick that has room for it.
    var nextDayStartMs = Int64.min
    var dayChangePending = false

    for (timeMs, x) in zip(timesAsc, positionsAsc) {
      if timeMs >= nextDayStartMs {
        let date = Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        nextDayStartMs = Int64(nextDay.timeIntervalSince1970 * 1000)
        dayChangePending = true
      }
      let isMajor = x - lastMajorX >= majorSpacing || (dayChangePending && x - lastMajorX >= minorSpacing)
      guard isMajor || x - lastMinorX >= minorSpacing else { continue }
      lastMinorX = x

      var label: String?
      if isMajor {
        lastMajorX = x
        let text = labelText(timeMs, dayChangePending)
        let width = labelWidth(text, dayChangePending)
        // Space against where the label is really drawn.
        let originX = labelOriginX(centeredAt: x, width: width, viewWidth: viewWidth)
        if text != lastLabelText, originX >= lastLabelMaxX + labelGap {
          label = text
          lastLabelText = text
          lastLabelMaxX = originX + width
        }
      }
      let emphasized = label != nil && dayChangePending
      if emphasized { dayChangePending = false }
      ticks.append(TimelineTick(x: x, isMajor: isMajor, label: label, emphasized: emphasized))
    }
    return ticks
  }

  /// Index of the first tick at or right of `x`; `ticks` is sorted by position.
  static func firstIndex(atOrAfter x: CGFloat, in ticks: [TimelineTick]) -> Int {
    var low = 0
    var high = ticks.count
    while low < high {
      let mid = (low + high) / 2
      if ticks[mid].x < x { low = mid + 1 } else { high = mid }
    }
    return low
  }
}
