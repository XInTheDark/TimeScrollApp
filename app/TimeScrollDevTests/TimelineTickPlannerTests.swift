import CoreGraphics
import Foundation
import Testing
@testable import TimeScroll

struct TimelineTickPlannerTests {
  private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  private func plan(times: [Int64], positions: [CGFloat], viewWidth: CGFloat = 5_000) -> [TimelineTick] {
    TimelineTickPlanner.plan(
      timesAsc: times,
      positionsAsc: positions,
      viewWidth: viewWidth,
      calendar: calendar,
      labelText: { ms, includesDay in includesDay ? "D\(ms / 86_400_000) \(ms)" : "\(ms)" },
      labelWidth: { text, _ in CGFloat(text.count) * 6 }
    )
  }

  /// One snapshot per hour for 3 days, 30pt apart.
  private var threeDays: (times: [Int64], positions: [CGFloat]) {
    let times = (0..<72).map { Int64($0) * 3_600_000 }
    return (times, times.indices.map { CGFloat($0) * 30 })
  }

  @Test func labels_never_overlap() {
    let (times, positions) = threeDays
    let ticks = plan(times: times, positions: positions)
    var lastMax = -CGFloat.greatestFiniteMagnitude
    for tick in ticks {
      guard let label = tick.label else { continue }
      let width = CGFloat(label.count) * 6
      let origin = TimelineTickPlanner.labelOriginX(centeredAt: tick.x, width: width, viewWidth: 5_000)
      #expect(origin >= lastMax + TimelineTickPlanner.labelGap)
      lastMax = origin + width
    }
  }

  @Test func each_day_is_announced_once_with_an_emphasized_label() {
    let (times, positions) = threeDays
    let days = plan(times: times, positions: positions).filter(\.emphasized)
    #expect(days.count == 3)
    #expect(days.allSatisfy { $0.label != nil })
  }

  @Test func ticks_are_sorted_and_firstIndex_finds_the_visible_slice() {
    let (times, positions) = threeDays
    let ticks = plan(times: times, positions: positions)
    #expect(ticks.map(\.x) == ticks.map(\.x).sorted())
    let index = TimelineTickPlanner.firstIndex(atOrAfter: 500, in: ticks)
    #expect(ticks[index].x >= 500)
    #expect(index == 0 || ticks[index - 1].x < 500)
    #expect(TimelineTickPlanner.firstIndex(atOrAfter: 1_000_000, in: ticks) == ticks.count)
  }

  @Test func empty_input_plans_nothing() {
    #expect(plan(times: [], positions: []).isEmpty)
  }
}
