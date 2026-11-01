import CoreGraphics
import Testing
@testable import TimeScroll

struct AXRectSubtractionTests {
  private let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

  @Test func noOccludersLeavesTheRect() {
    #expect(RectSubtraction.uncovered(rect, by: []) == [rect])
    #expect(RectSubtraction.uncovered(rect, by: [CGRect(x: 200, y: 200, width: 10, height: 10)]) == [rect])
  }

  @Test func touchingEdgesDoNotCut() {
    #expect(RectSubtraction.uncovered(rect, by: [CGRect(x: 100, y: 0, width: 50, height: 100)]) == [rect])
  }

  @Test func fullCoverLeavesNothing() {
    #expect(RectSubtraction.uncovered(rect, by: [CGRect(x: -10, y: -10, width: 200, height: 200)]).isEmpty)
  }

  @Test func centerHoleLeavesFourDisjointPieces() {
    let pieces = RectSubtraction.uncovered(rect, by: [CGRect(x: 25, y: 25, width: 50, height: 50)])
    #expect(pieces.count == 4)
    #expect(RectSubtraction.area(pieces) == CGFloat(7_500))
    for (i, a) in pieces.enumerated() {
      for b in pieces[(i + 1)...] { #expect(a.intersection(b).width * a.intersection(b).height == 0) }
    }
  }

  @Test func overlappingOccludersAreNotCountedTwice() {
    let pieces = RectSubtraction.uncovered(rect, by: [
      CGRect(x: 0, y: 0, width: 60, height: 100),
      CGRect(x: 40, y: 0, width: 30, height: 100),
    ])
    #expect(RectSubtraction.area(pieces) == CGFloat(3_000))
  }

  @Test func emptyRectHasNoPieces() {
    #expect(RectSubtraction.uncovered(.zero, by: []).isEmpty)
    #expect(RectSubtraction.uncovered(.null, by: []).isEmpty)
  }

  @Test func pieceCapOverestimatesInsteadOfGrowing() {
    // A grid of small holes would split the rect into many pieces.
    let holes = (0..<10).flatMap { x in (0..<10).map { y in CGRect(x: x * 10 + 2, y: y * 10 + 2, width: 4, height: 4) } }
    let pieces = RectSubtraction.uncovered(rect, by: holes, maxPieces: 16)
    #expect(pieces.count <= 64)
    #expect(RectSubtraction.area(pieces) >= CGFloat(8_400))
  }

  @Test func givesUpOnceTooLittleRemains() {
    let occluders = [CGRect(x: 0, y: 0, width: 100, height: 95)]
    #expect(RectSubtraction.uncovered(rect, by: occluders, minArea: 1_000).isEmpty)
    #expect(RectSubtraction.area(RectSubtraction.uncovered(rect, by: occluders, minArea: 500)) == CGFloat(500))
    #expect(RectSubtraction.uncovered(CGRect(x: 0, y: 0, width: 10, height: 10), by: [], minArea: 101).isEmpty)
  }
}
