import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import TimeScroll

/// Benchmarks of the Direct-mode (Accessibility) text pipeline on large synthetic data. Opt-in:
/// run with `TEST_RUNNER_TIMESCROLL_BENCHMARKS=1` (CI does). Timings are reported, not gated, since
/// shared runners are noisy; element and read counts are deterministic and gated.
/// With `TIMESCROLL_BENCHMARK_OUTPUT` set, results are also written there as JSON.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARKS"] == "1"))
struct AXExtractionBenchmarks {
  private static let window = CGRect(x: 0, y: 0, width: 1440, height: 900)
  private static let viewport = CGRect(x: 0, y: 80, width: 1440, height: 820)

  private func report(_ name: String, _ value: Double, _ unit: String) {
    print(String(format: "BENCH %@ %.3f %@", name, value, unit))
    guard let path = ProcessInfo.processInfo.environment["TIMESCROLL_BENCHMARK_OUTPUT"] else { return }
    let line = "{\"name\":\"\(name)\",\"value\":\(value),\"unit\":\"\(unit)\"}\n"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
  }

  /// Median wall time of `runs` calls, in milliseconds.
  private func medianMs(runs: Int, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    for _ in 0..<runs {
      let start = DispatchTime.now().uptimeNanoseconds
      body()
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return samples.sorted()[samples.count / 2]
  }

  private func walk(_ tree: FakeAXTree, root: Int = 0) -> (text: AXWindowText, visited: Int) {
    let walker = AXTreeWalker(source: tree, limits: .default, deadline: AXDeadline(limits: .default), visibleRects: [Self.window])
    walker.walk(root)
    return (walker.finish(), walker.visitedCount)
  }

  /// A web page of `paragraphs` blocks (40 pt each, a group holding a text run) scrolled to `scroll`.
  private func webPage(paragraphs: Int, scroll: CGFloat, nesting: Int = 1) -> FakeAXTree {
    let tree = FakeAXTree()
    let blocks = (0..<paragraphs).map { 1_000 + $0 * (nesting + 1) }
    tree[0] = .init(role: "AXWindow", children: [1], frame: Self.window)
    tree[1] = .init(role: "AXScrollArea", children: [2], frame: Self.viewport)
    tree[2] = .init(role: "AXWebArea", children: blocks)
    for (index, id) in blocks.enumerated() {
      let frame = CGRect(x: 0, y: Self.viewport.minY + CGFloat(index) * 40 - scroll, width: 1440, height: 40)
      // `nesting` wrapper groups (Electron-style divs), then the text run.
      for level in 0..<nesting { tree[id + level] = .init(role: "AXGroup", children: [id + level + 1], frame: frame) }
      tree[id + nesting] = .init(role: "AXStaticText", value: "Paragraph \(index) with some words in it", frame: frame)
    }
    return tree
  }

  @Test func longWebPageReadsOnlyTheViewport() {
    let tree = webPage(paragraphs: 20_000, scroll: 400_000)
    let result = walk(tree)
    // 820 pt viewport / 40 pt blocks: about 21 blocks on screen.
    let lines = result.text.text.split(separator: "\n")
    #expect((20...23).contains(lines.count))
    #expect(lines.first?.hasPrefix("Paragraph 9999") == true || lines.first?.hasPrefix("Paragraph 10000") == true)
    #expect(result.visited < 120)
    report("ax.webpage20k.visited", Double(result.visited), "elements")
    report("ax.webpage20k.frameProbes", Double(tree.frameReads), "reads")
    report("ax.webpage20k.walk", medianMs(runs: 50) { _ = walk(tree) }, "ms")
  }

  @Test func deeplyNestedChatReadsOnlyTheViewport() {
    let tree = webPage(paragraphs: 2_000, scroll: 40_000, nesting: 30)
    let result = walk(tree)
    #expect(result.visited < 1_200)
    report("ax.chat2k.nested30.visited", Double(result.visited), "elements")
    report("ax.chat2k.nested30.walk", medianMs(runs: 50) { _ = walk(tree) }, "ms")
  }

  @Test func unorderedSiblingsWorstCase() {
    // Siblings whose frames are not top to bottom cannot be skipped; each is read and culled.
    let tree = FakeAXTree()
    let count = 5_000
    tree[0] = .init(role: "AXWindow", children: (0..<count).map { 10 + $0 }, frame: Self.window)
    for index in 0..<count {
      let slot = (index * 7_919) % count
      tree[10 + index] = .init(role: "AXStaticText", value: "item \(slot)",
                               frame: CGRect(x: 0, y: CGFloat(slot) * 20, width: 400, height: 20))
    }
    let result = walk(tree)
    #expect(result.text.text.split(separator: "\n").count == 45)
    report("ax.unordered5k.visited", Double(result.visited), "elements")
    report("ax.unordered5k.walk", medianMs(runs: 20) { _ = walk(tree) }, "ms")
  }

  @Test func planningManyWindows() {
    let display = CGRect(x: 0, y: 0, width: 3008, height: 1692)
    let windows = (0..<400).map { (i: Int) -> AXScreenWindow in
      let origin = CGPoint(x: CGFloat(i % 20) * 120, y: CGFloat(i / 20) * 60)
      let layer = i % 50 == 0 ? 3 : 0
      return AXScreenWindow(id: CGWindowID(i), pid: pid_t(i % 40), layer: layer, alpha: 1,
                            bounds: CGRect(origin: origin, size: CGSize(width: 1200, height: 900)))
    }
    var planned: [AXPlannedWindow] = []
    let ms = medianMs(runs: 200) { planned = AXWindowPlanner.plan(windows: windows, displayBounds: display, maxWindows: 16) { _ in false } }
    #expect(!planned.isEmpty && planned.count <= 16)
    report("ax.plan400windows", ms * 1_000, "us")
  }

  @Test func reuseDecisionForAFullDisplay() throws {
    var pb: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb) == kCVReturnSuccess)
    let buffer = try #require(pb)
    let grid = try #require(LumaGridSignature(pixelBuffer: buffer))
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let plan = (0..<16).map { (i: Int) -> AXPlannedWindow in
      let origin = CGPoint(x: CGFloat(i % 4) * 480, y: CGFloat(i / 4) * 270)
      let bounds = CGRect(origin: origin, size: CGSize(width: 480, height: 270))
      return AXPlannedWindow(window: AXScreenWindow(id: CGWindowID(i), pid: 1, layer: 0, alpha: 1, bounds: bounds),
                             visibleRects: [bounds])
    }
    let cache = AXWindowTextCache()
    let results = plan.map { _ in AXWindowTextCache.Result(text: AXWindowText(text: "x\n", count: 2, boxes: []), documents: [], isFresh: true) }
    cache.store(plan: plan, results: results, grid: grid, now: 0)
    var reused: [AXWindowText?] = []
    let ms = medianMs(runs: 500) { reused = cache.reusableText(for: plan, grid: grid, displayBounds: display, now: 1) }
    #expect(reused.allSatisfy { $0 != nil })
    report("ax.reuseDecision16windows", ms * 1_000, "us")
  }
}
