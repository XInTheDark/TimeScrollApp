import CoreGraphics
import Foundation
import Testing
@testable import TimeScroll

struct AXWindowPlannerTests {
  private static let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)

  private func window(_ id: CGWindowID, pid: pid_t = 1, layer: Int = 0, alpha: Double = 1, _ bounds: CGRect) -> AXScreenWindow {
    AXScreenWindow(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
  }

  private func plan(_ windows: [AXScreenWindow], display: CGRect = display, maxWindows: Int = 16,
                    excluded: Set<pid_t> = []) -> [AXPlannedWindow] {
    AXWindowPlanner.plan(windows: windows, displayBounds: display, maxWindows: maxWindows) { excluded.contains($0) }
  }

  // MARK: - Parsing

  @Test func parsesWindowListAndDropsMalformedEntries() {
    let bounds = CGRect(x: 10, y: 20, width: 300, height: 200).dictionaryRepresentation as NSDictionary
    let info: [[String: Any]] = [
      [kCGWindowNumber as String: CGWindowID(7), kCGWindowOwnerPID as String: pid_t(42), kCGWindowBounds as String: bounds,
       kCGWindowLayer as String: 3, kCGWindowAlpha as String: 0.5],
      [kCGWindowNumber as String: CGWindowID(8), kCGWindowOwnerPID as String: pid_t(43), kCGWindowBounds as String: bounds],
      [kCGWindowOwnerPID as String: pid_t(44), kCGWindowBounds as String: bounds],
      [kCGWindowNumber as String: CGWindowID(9), kCGWindowOwnerPID as String: pid_t(45)],
    ]
    let parsed = AXScreenWindow.parse(info)
    #expect(parsed == [
      AXScreenWindow(id: 7, pid: 42, layer: 3, alpha: 0.5, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)),
      AXScreenWindow(id: 8, pid: 43, layer: 0, alpha: 1, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)),
    ])
  }

  @Test func emptyInputsPlanNothing() {
    #expect(plan([]).isEmpty)
    #expect(plan([window(1, CGRect(x: 0, y: 0, width: 500, height: 500))], display: .zero).isEmpty)
    #expect(plan([window(1, CGRect(x: 0, y: 0, width: 500, height: 500))], maxWindows: 0).isEmpty)
  }

  // MARK: - Displays

  @Test func windowsOnAnotherDisplayAreNotRead() {
    let planned = plan([
      window(1, CGRect(x: 1200, y: 0, width: 800, height: 800)),
      window(2, CGRect(x: 0, y: 0, width: 800, height: 800)),
    ])
    #expect(planned.map(\.window.id) == [2])
  }

  @Test func windowSpanningDisplaysIsClippedToThisDisplay() {
    let planned = plan([window(1, CGRect(x: 600, y: 0, width: 800, height: 1000))])
    #expect(planned.first?.visibleRects == [CGRect(x: 600, y: 0, width: 400, height: 1000)])
  }

  @Test func displayLeftOfTheMainOneUsesNegativeCoordinates() {
    let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let planned = plan([
      window(1, CGRect(x: -1400, y: 100, width: 1000, height: 700)),
      window(2, CGRect(x: 100, y: 100, width: 1000, height: 700)),
    ], display: left)
    #expect(planned.map(\.window.id) == [1])
  }

  // MARK: - Visibility

  @Test func mostlyCoveredWindowIsSkippedDeterministically() {
    let front = window(1, CGRect(x: 0, y: 0, width: 1000, height: 950))
    let back = window(2, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    // 5% of the display shows the back window: below the 10% threshold, every time.
    for _ in 0..<20 { #expect(plan([front, back]).map(\.window.id) == [1]) }
  }

  @Test func windowShowingExactlyTheThresholdIsRead() {
    let front = window(1, CGRect(x: 0, y: 0, width: 1000, height: 900))
    let back = window(2, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let planned = plan([front, back])
    #expect(planned.map(\.window.id) == [1, 2])
    #expect(planned[1].visibleRects == [CGRect(x: 0, y: 900, width: 1000, height: 100)])
  }

  @Test func smallWindowsAreSkipped() {
    #expect(plan([window(1, CGRect(x: 0, y: 0, width: 300, height: 300))]).isEmpty)
  }

  @Test func overlaysAndChromeNeitherReadNorOcclude() {
    let menuBar = window(1, layer: 24, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let dock = window(2, layer: 20, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let content = window(3, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let planned = plan([menuBar, dock, content])
    #expect(planned.map(\.window.id) == [3])
    #expect(planned[0].visibleRects == [CGRect(x: 0, y: 0, width: 1000, height: 1000)])
  }

  @Test func floatingPanelsAreReadAndOcclude() {
    let panel = window(1, layer: 3, CGRect(x: 0, y: 0, width: 1000, height: 950))
    let content = window(2, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    #expect(plan([panel, content]).map(\.window.id) == [1])
  }

  @Test func translucentWindowsDoNotOccludeAndInvisibleOnesAreIgnored() {
    let translucent = window(1, alpha: 0.5, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let invisible = window(2, alpha: 0.001, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let content = window(3, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    #expect(plan([translucent, invisible, content]).map(\.window.id) == [1, 3])
  }

  @Test func excludedAppsAreNotReadButStillOcclude() {
    let secret = window(1, pid: 9, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let below = window(2, pid: 1, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    #expect(plan([secret, below], excluded: [9]).isEmpty)
  }

  @Test func stopsAtMaxWindows() {
    let windows = (0..<5).map { window(CGWindowID($0), CGRect(x: CGFloat($0) * 200, y: 0, width: 200, height: 1000)) }
    #expect(plan(windows, maxWindows: 3).map(\.window.id) == [0, 1, 2])
  }

  @Test func handlesManyOverlappingWindowsCheaply() {
    // A deep stack of cascaded windows; each still shows a strip.
    let windows = (0..<200).map { i in
      window(CGWindowID(i), CGRect(x: CGFloat(i) * 2, y: CGFloat(i) * 2, width: 800, height: 800))
    }
    let planned = plan(windows)
    #expect(planned.first?.window.id == 0)
    #expect(planned.count <= 16)
  }
}
