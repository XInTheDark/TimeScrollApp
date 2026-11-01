import CoreGraphics
import Testing
@testable import TimeScroll

struct AXSiblingScanTests {
  private func rows(_ count: Int, height: CGFloat = 20) -> (Int) -> CGRect? {
    { CGRect(x: 0, y: CGFloat($0) * height, width: 100, height: height) }
  }

  @Test func detectsTopToBottomLayout() {
    #expect(AXSiblingScan.isTopToBottom(count: 100, frameAt: rows(100)))
    #expect(!AXSiblingScan.isTopToBottom(count: 2, frameAt: rows(2)))
    #expect(!AXSiblingScan.isTopToBottom(count: 100) { _ in CGRect(x: 0, y: 0, width: 10, height: 10) })
    #expect(!AXSiblingScan.isTopToBottom(count: 100) { $0 == 50 ? nil : CGRect(x: 0, y: CGFloat($0), width: 1, height: 1) })
    #expect(!AXSiblingScan.isTopToBottom(count: 100) { CGRect(x: 0, y: CGFloat(100 - $0), width: 1, height: 1) })
  }

  @Test func findsFirstSiblingReachingTheTop() {
    // Row i spans y 20i..<20i+20; the first reaching y=1000 is row 49 (maxY 1000), started one early.
    #expect(AXSiblingScan.firstReaching(top: 1000, count: 1000, frameAt: rows(1000)) == 48)
    #expect(AXSiblingScan.firstReaching(top: 0, count: 1000, frameAt: rows(1000)) == 0)
    #expect(AXSiblingScan.firstReaching(top: -500, count: 10, frameAt: rows(10)) == 0)
    #expect(AXSiblingScan.firstReaching(top: 1_000_000, count: 10, frameAt: rows(10)) == 9)
  }

  @Test func missingFrameRestartsFromTheBeginning() {
    #expect(AXSiblingScan.firstReaching(top: 1000, count: 1000) { $0 == 500 ? nil : CGRect(x: 0, y: CGFloat($0) * 20, width: 1, height: 20) } == 0)
  }

  @Test func binarySearchProbesLogarithmically() {
    var probes = 0
    _ = AXSiblingScan.firstReaching(top: 123_456, count: 100_000) { index in
      probes += 1
      return CGRect(x: 0, y: CGFloat(index) * 20, width: 1, height: 20)
    }
    #expect(probes <= 17)
  }
}
