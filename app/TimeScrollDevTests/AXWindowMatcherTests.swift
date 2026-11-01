import CoreGraphics
import Testing
@testable import TimeScroll

struct AXWindowMatcherTests {
  private let target = CGRect(x: 100, y: 100, width: 800, height: 600)

  @Test func picksTheClosestFrameWithinTolerance() {
    let frames: [CGRect?] = [
      CGRect(x: 0, y: 0, width: 400, height: 300),
      CGRect(x: 102, y: 101, width: 800, height: 600),
      nil,
      CGRect(x: 100, y: 100, width: 800, height: 600),
    ]
    #expect(AXWindowMatcher.bestMatch(for: target, among: frames) == 3)
  }

  @Test func noMatchBeyondTolerance() {
    #expect(AXWindowMatcher.bestMatch(for: target, among: [CGRect(x: 160, y: 100, width: 800, height: 600)]) == nil)
    #expect(AXWindowMatcher.bestMatch(for: target, among: []) == nil)
    #expect(AXWindowMatcher.bestMatch(for: target, among: [nil, nil]) == nil)
  }
}
