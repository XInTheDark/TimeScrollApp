import CoreGraphics
import Testing
@testable import TimeScroll

struct SnapshotToolbarPlacementTests {
  private let container = CGSize(width: 1_000, height: 600)
  private let toolbar = CGSize(width: 600, height: 40)

  @Test func offsetsInsideAreKept() {
    #expect(SnapshotToolbarPlacement.clamped(offset: CGSize(width: 50, height: 220), toolbar: toolbar, in: container)
            == CGSize(width: 50, height: 220))
  }

  @Test func offsetsOutsideAreClampedToTheEdges() {
    let limitX = (1_000 - 600) / 2 - SnapshotToolbarPlacement.margin
    let limitY = (600 - 40) / 2 - SnapshotToolbarPlacement.margin
    #expect(SnapshotToolbarPlacement.clamped(offset: CGSize(width: 900, height: -900), toolbar: toolbar, in: container)
            == CGSize(width: limitX, height: -limitY))
  }

  @Test func aToolbarWiderThanTheStageIsCentered() {
    #expect(SnapshotToolbarPlacement.clamped(offset: CGSize(width: 40, height: 10), toolbar: CGSize(width: 1_200, height: 40), in: container).width == 0)
  }

  @Test func beforeMeasuringTheToolbarAnOffsetStillStaysInside() {
    let clamped = SnapshotToolbarPlacement.clamped(offset: CGSize(width: 0, height: 5_000), toolbar: .zero, in: container)
    #expect(clamped.height == 300 - SnapshotToolbarPlacement.margin)
  }
}
