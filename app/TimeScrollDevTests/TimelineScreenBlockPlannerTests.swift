import CoreGraphics
import Testing
@testable import TimeScroll

struct TimelineScreenBlockPlannerTests {
  private typealias Span = TimelineScreenBlockPlanner.Span

  @Test func emptyInputHasNoBlocks() {
    #expect(TimelineScreenBlockPlanner.plan(spans: [], fillsGaps: true).isEmpty)
  }

  @Test func singleSnapshotGetsMinimumWidth() {
    let blocks = TimelineScreenBlockPlanner.plan(spans: [Span(x0: 10, x1: 10, appBundleId: "a")], fillsGaps: true)
    #expect(blocks == [TimelineScreenBlock(x0: 10, x1: 14, appBundleId: "a")])
  }

  @Test func compressedMergesSparseSameAppSnapshotsIntoOneBlock() {
    // Idle screen: one capture every few minutes, each its own zero-width segment 18 pt apart.
    let spans = (0..<10).map { Span(x0: CGFloat($0) * 18, x1: CGFloat($0) * 18, appBundleId: "a") }
    let blocks = TimelineScreenBlockPlanner.plan(spans: spans, fillsGaps: true)
    #expect(blocks.count == 1)
    #expect(blocks[0].x0 == 0)
    #expect(blocks[0].x1 == 162)
  }

  @Test func compressedFillsUpToNextAppWithGutter() {
    let spans = [Span(x0: 0, x1: 0, appBundleId: "a"), Span(x0: 18, x1: 40, appBundleId: "b")]
    let blocks = TimelineScreenBlockPlanner.plan(spans: spans, fillsGaps: true)
    #expect(blocks == [
      TimelineScreenBlock(x0: 0, x1: 16, appBundleId: "a"),
      TimelineScreenBlock(x0: 18, x1: 40, appBundleId: "b"),
    ])
  }

  @Test func denseSwitchingDrawsTouchingBlocks() {
    let spans = [Span(x0: 0, x1: 0, appBundleId: "a"), Span(x0: 3, x1: 3, appBundleId: "b"), Span(x0: 6, x1: 6, appBundleId: "a")]
    let blocks = TimelineScreenBlockPlanner.plan(spans: spans, fillsGaps: true)
    #expect(blocks.map(\.x1) == [3, 6, 10])
    #expect(blocks.allSatisfy { $0.width >= 1 })
  }

  @Test func linearKeepsRealGapsButWidensSlivers() {
    let spans = [Span(x0: 0, x1: 0, appBundleId: "a"), Span(x0: 100, x1: 100, appBundleId: "a")]
    let blocks = TimelineScreenBlockPlanner.plan(spans: spans, fillsGaps: false)
    #expect(blocks == [
      TimelineScreenBlock(x0: 0, x1: 4, appBundleId: "a"),
      TimelineScreenBlock(x0: 100, x1: 104, appBundleId: "a"),
    ])
  }

  @Test func blockEndsRiseForVisibleSliceSearch() {
    let spans = (0..<1_000).map { Span(x0: CGFloat($0) * 5, x1: CGFloat($0) * 5 + 1, appBundleId: $0 % 3 == 0 ? "a" : "b") }
    let blocks = TimelineScreenBlockPlanner.plan(spans: spans, fillsGaps: true)
    #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $0.x1 <= $1.x1 })
    let index = TimelineScreenBlockPlanner.firstIndex(endingAtOrAfter: 2_500, in: blocks)
    #expect(blocks[index].x1 >= 2_500)
    #expect(index == 0 || blocks[index - 1].x1 < 2_500)
  }
}
