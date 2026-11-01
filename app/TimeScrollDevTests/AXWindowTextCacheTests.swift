import CoreGraphics
import CoreVideo
import Testing
@testable import TimeScroll

struct AXWindowTextCacheTests {
  // 640x360 frames over a 640x360 pt display: every grid cell is 10x10 pt.
  private static let display = CGRect(x: 0, y: 0, width: 640, height: 360)

  /// NV12 frame with uniform luma; `patches` paint luma rectangles (x, y, w, h, value) in pixels.
  private func grid(patches: [(Int, Int, Int, Int, UInt8)] = []) throws -> LumaGridSignature {
    var pb: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb) == kCVReturnSuccess)
    let buffer = try #require(pb)
    CVPixelBufferLockBaseAddress(buffer, [])
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let pixels = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<360 { for x in 0..<640 { pixels[y * stride + x] = 200 } }
    for (px, py, pw, ph, value) in patches {
      for y in py..<(py + ph) { for x in px..<(px + pw) { pixels[y * stride + x] = value } }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return try #require(LumaGridSignature(pixelBuffer: buffer))
  }

  private func planned(_ id: CGWindowID, pid: pid_t = 1, _ bounds: CGRect, visible: [CGRect]? = nil) -> AXPlannedWindow {
    AXPlannedWindow(window: AXScreenWindow(id: id, pid: pid, layer: 0, alpha: 1, bounds: bounds), visibleRects: visible ?? [bounds])
  }

  private func text(_ s: String) -> AXWindowText { AXWindowText(text: s, count: s.count, boxes: []) }

  private func fresh(_ s: String) -> AXWindowTextCache.Result {
    AXWindowTextCache.Result(text: text(s), documents: [], isFresh: true)
  }

  private let left = CGRect(x: 0, y: 0, width: 320, height: 360)
  private let right = CGRect(x: 320, y: 0, width: 320, height: 360)

  // MARK: - Reuse decisions

  @Test func nothingIsReusedWithoutGrids() throws {
    let cache = AXWindowTextCache()
    let plan = [planned(1, left)]
    #expect(cache.reusableText(for: plan, grid: try grid(), displayBounds: Self.display, now: 0) == [nil])
    cache.store(plan: plan, results: [fresh("a")], grid: nil, now: 0)
    #expect(cache.reusableText(for: plan, grid: try grid(), displayBounds: Self.display, now: 1) == [nil])
    cache.store(plan: plan, results: [fresh("a")], grid: try grid(), now: 1)
    #expect(cache.reusableText(for: plan, grid: nil, displayBounds: Self.display, now: 2) == [nil])
  }

  @Test func onlyWindowsUnderChangedCellsAreReadAgain() throws {
    let cache = AXWindowTextCache()
    let plan = [planned(1, left), planned(2, right)]
    cache.store(plan: plan, results: [fresh("left"), fresh("right")], grid: try grid(), now: 0)
    // Typing in the right window changes one cell there.
    let typed = try grid(patches: [(400, 100, 10, 10, 40)])
    #expect(cache.reusableText(for: plan, grid: typed, displayBounds: Self.display, now: 5) == [text("left"), nil])
    #expect(cache.reusableText(for: plan, grid: try grid(), displayBounds: Self.display, now: 5) == [text("left"), text("right")])
  }

  @Test func changeInACoveredPartDoesNotForceARead() throws {
    let cache = AXWindowTextCache()
    let visible = [CGRect(x: 0, y: 0, width: 320, height: 100)]
    let plan = [planned(1, left, visible: visible)]
    cache.store(plan: plan, results: [fresh("strip")], grid: try grid(), now: 0)
    let changedBelow = try grid(patches: [(100, 200, 10, 10, 40)])
    #expect(cache.reusableText(for: plan, grid: changedBelow, displayBounds: Self.display, now: 1) == [text("strip")])
  }

  @Test func movedResizedUncoveredOrReplacedWindowsAreReadAgain() throws {
    let cache = AXWindowTextCache()
    cache.store(plan: [planned(1, left)], results: [fresh("a")], grid: try grid(), now: 0)
    let same = try grid()
    #expect(cache.reusableText(for: [planned(1, left.offsetBy(dx: 10, dy: 0))], grid: same, displayBounds: Self.display, now: 1) == [nil])
    #expect(cache.reusableText(for: [planned(1, left, visible: [left.insetBy(dx: 0, dy: 50)])], grid: same, displayBounds: Self.display, now: 1) == [nil])
    #expect(cache.reusableText(for: [planned(1, pid: 2, left)], grid: same, displayBounds: Self.display, now: 1) == [nil])
    #expect(cache.reusableText(for: [planned(9, left)], grid: same, displayBounds: Self.display, now: 1) == [nil])
  }

  @Test func reusedTextExpires() throws {
    let cache = AXWindowTextCache()
    let plan = [planned(1, left)]
    cache.store(plan: plan, results: [fresh("a")], grid: try grid(), now: 100)
    let same = try grid()
    #expect(cache.reusableText(for: plan, grid: same, displayBounds: Self.display, now: 129) == [text("a")])
    #expect(cache.reusableText(for: plan, grid: same, displayBounds: Self.display, now: 130) == [nil])
    // A clock that went backwards (sleep, restart) never reuses.
    #expect(cache.reusableText(for: plan, grid: same, displayBounds: Self.display, now: 50) == [nil])
  }

  @Test func reuseKeepsTheOriginalReadTime() throws {
    let cache = AXWindowTextCache()
    let plan = [planned(1, left)]
    cache.store(plan: plan, results: [fresh("a")], grid: try grid(), now: 0)
    // Reused at 20: the entry still dates from 0, so it expires at 30, not 50.
    cache.store(plan: plan, results: [AXWindowTextCache.Result(text: text("a"), documents: [], isFresh: false)], grid: try grid(), now: 20)
    #expect(cache.reusableText(for: plan, grid: try grid(), displayBounds: Self.display, now: 29) == [text("a")])
    #expect(cache.reusableText(for: plan, grid: try grid(), displayBounds: Self.display, now: 30) == [nil])
  }

  @Test func unreadableWindowsAreNotCached() throws {
    let cache = AXWindowTextCache()
    let plan = [planned(1, left)]
    cache.store(plan: plan, results: [AXWindowTextCache.Result(text: .empty, documents: [], isFresh: true, isCacheable: false)], grid: try grid(), now: 0)
    #expect(cache.reusableText(for: plan, grid: try grid(), displayBounds: Self.display, now: 1) == [nil])
  }

  @Test func removeAllForgetsEverything() throws {
    let cache = AXWindowTextCache()
    let plan = [planned(1, left)]
    cache.store(plan: plan, results: [fresh("a")], grid: try grid(), now: 0)
    cache.removeAll()
    #expect(cache.reusableText(for: plan, grid: try grid(), displayBounds: Self.display, now: 1) == [nil])
  }

  // MARK: - Grid geometry

  private func mask(changed cells: [(Int, Int)]) -> [Bool] {
    var mask = [Bool](repeating: false, count: LumaGridSignature.columns * LumaGridSignature.rows)
    for (column, row) in cells { mask[row * LumaGridSignature.columns + column] = true }
    return mask
  }

  @Test func rectOnCellBoundaryDoesNotTouchTheNeighbour() {
    // Cell (2, 0) spans x 20..<30. A rect ending exactly at x=20 does not reach it.
    let m = mask(changed: [(2, 0)])
    #expect(!AXWindowTextCache.touchesChangedCell([CGRect(x: 0, y: 0, width: 20, height: 10)], changedMask: m, displayBounds: Self.display))
    #expect(AXWindowTextCache.touchesChangedCell([CGRect(x: 0, y: 0, width: 20.5, height: 10)], changedMask: m, displayBounds: Self.display))
  }

  @Test func offsetDisplayMapsCellsFromItsOrigin() {
    let display = CGRect(x: -640, y: -360, width: 640, height: 360)
    let m = mask(changed: [(63, 35)])
    #expect(AXWindowTextCache.touchesChangedCell([CGRect(x: -5, y: -5, width: 5, height: 5)], changedMask: m, displayBounds: display))
    #expect(!AXWindowTextCache.touchesChangedCell([CGRect(x: -640, y: -360, width: 5, height: 5)], changedMask: m, displayBounds: display))
    // Off this display entirely.
    #expect(!AXWindowTextCache.touchesChangedCell([CGRect(x: 10, y: 10, width: 5, height: 5)], changedMask: m, displayBounds: display))
  }

  @Test func malformedMaskCountsAsChanged() {
    #expect(AXWindowTextCache.touchesChangedCell([CGRect(x: 0, y: 0, width: 5, height: 5)], changedMask: [false], displayBounds: Self.display))
  }

  @Test func changedCellMaskMatchesChangedCellCount() throws {
    let base = try grid()
    let changed = try grid(patches: [(0, 0, 10, 10, 40), (630, 350, 10, 10, 40)])
    let m = try #require(changed.changedCellMask(comparedTo: base))
    #expect(m.filter { $0 }.count == changed.changedCells(comparedTo: base))
    #expect(m.first == true && m.last == true)
  }
}
