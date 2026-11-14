import AppKit
import Testing
@testable import TimeScroll

struct TimelineWarpPointMarksTests {
  private func point(_ ms: Int64, _ note: String = "") -> TimeWarpPointNote {
    TimeWarpPointNote(timeMs: ms, note: note, appBundleId: nil)
  }

  private let headY = TimelineWarpPointMarks.headCenterY

  @Test func positionsAreSortedWithTheirPoints() {
    let marks = TimelineWarpPointMarks(points: [point(300, "c"), point(100, "a"), point(200, "b")], x: { CGFloat($0) })
    #expect(marks.xs == [100, 200, 300])
    #expect(marks.points.map(\.note) == ["a", "b", "c"])
  }

  @Test func visibleIndicesIncludeHeadsAtTheEdges() {
    let marks = TimelineWarpPointMarks(points: (0..<10).map { point(Int64($0) * 100) }, x: { CGFloat($0) })
    #expect(marks.indices(from: 150, to: 450) == 2..<5)
    // Heads are 8 pt wide: 300's head reaches 304, and 400's starts at 396.
    #expect(marks.indices(from: 305, to: 395).isEmpty)
    #expect(marks.indices(from: 302, to: 398) == 3..<5)
    #expect(marks.indices(from: 2_000, to: 3_000).isEmpty)
    #expect(TimelineWarpPointMarks.empty.indices(from: 0, to: 1_000).isEmpty)
  }

  @Test func hitFindsTheNearestHeadOnlyNearTheTop() {
    let marks = TimelineWarpPointMarks(points: [point(100, "a"), point(106, "b"), point(300, "c")], x: { CGFloat($0) })
    #expect(marks.hit(NSPoint(x: 101, y: headY))?.note == "a")
    #expect(marks.hit(NSPoint(x: 105, y: headY))?.note == "b")
    #expect(marks.hit(NSPoint(x: 307, y: headY + 3))?.note == "c")
    #expect(marks.hit(NSPoint(x: 200, y: headY)) == nil)
    #expect(marks.hit(NSPoint(x: 100, y: headY + 20)) == nil)
    #expect(TimelineWarpPointMarks.empty.hit(NSPoint(x: 0, y: headY)) == nil)
  }

  @Test func manyPointsStayCheap() {
    let marks = TimelineWarpPointMarks(points: (0..<100_000).map { point(Int64($0) * 10) }, x: { CGFloat($0) / 10 })
    // 101 in view, plus the heads poking in from either side.
    #expect((101...109).contains(marks.indices(from: 50_000, to: 50_100).count))
    #expect(marks.hit(NSPoint(x: 77_777, y: headY))?.timeMs == 777_770)
  }
}
