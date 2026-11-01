import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import TimeScroll

struct DuplicateDetectionTests {
  private static let width = 640
  private static let height = 360

  /// NV12 frame with a uniform luma plane; `patches` paint luma rectangles (x, y, w, h, value).
  private func makeFrame(
    luma: UInt8 = 200,
    patches: [(Int, Int, Int, Int, UInt8)] = [],
    format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    width: Int = width,
    height: Int = height
  ) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, format, nil, &pb)
    try #require(status == kCVReturnSuccess)
    let buffer = try #require(pb)
    guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return buffer }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let pixels = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
      for x in 0..<width { pixels[y * stride + x] = luma }
    }
    for (px, py, pw, ph, value) in patches {
      for y in py..<(py + ph) {
        for x in px..<(px + pw) { pixels[y * stride + x] = value }
      }
    }
    return buffer
  }

  private func grid(_ frame: CVPixelBuffer) throws -> LumaGridSignature {
    try #require(LumaGridSignature(pixelBuffer: frame))
  }

  private func makeOutput() -> FrameOutput {
    FrameOutput(onSnapshot: { _ in }, hevcStore: HEVCVideoStore(namespace: "dedup-tests"), displayBounds: .zero)
  }

  // Cells are 10x10 px on a 640x360 frame, so a 10x10 patch at a multiple of 10 fills one cell.
  private func cellPatch(_ column: Int, _ row: Int, value: UInt8 = 40) -> (Int, Int, Int, Int, UInt8) {
    (column * 10, row * 10, 10, 10, value)
  }

  // MARK: - LumaGridSignature

  @Test func identicalFramesChangeNoCells() throws {
    let a = try grid(makeFrame())
    let b = try grid(makeFrame())
    #expect(a.changedCells(comparedTo: b) == 0)
    #expect(a.cells.count == LumaGridSignature.columns * LumaGridSignature.rows)
  }

  @Test func nonNV12FrameHasNoSignature() throws {
    #expect(LumaGridSignature(pixelBuffer: try makeFrame(format: kCVPixelFormatType_32BGRA)) == nil)
  }

  @Test func frameSmallerThanGridHasNoSignature() throws {
    #expect(LumaGridSignature(pixelBuffer: try makeFrame(width: 32, height: 20)) == nil)
  }

  @Test func changeBelowCellThresholdIsIgnored() throws {
    let base = try grid(makeFrame(luma: 200))
    let shifted = try grid(makeFrame(luma: 198))
    #expect(base.changedCells(comparedTo: shifted) == 0)
  }

  @Test func countsEachChangedCell() throws {
    let base = try grid(makeFrame())
    let one = try grid(makeFrame(patches: [cellPatch(3, 4)]))
    let three = try grid(makeFrame(patches: [cellPatch(3, 4), cellPatch(10, 10), cellPatch(63, 35)]))
    #expect(base.changedCells(comparedTo: one) == 1)
    #expect(base.changedCells(comparedTo: three) == 3)
  }

  @Test func smallPatchInsideOneCellStillCounts() throws {
    // A 4x4 dark patch (glyph-sized at this scale) moves its cell's mean by ~25.
    let base = try grid(makeFrame())
    let glyph = try grid(makeFrame(patches: [(22, 22, 4, 4, 40)]))
    #expect(base.changedCells(comparedTo: glyph) == 1)
  }

  @Test func wholeScreenChangeCountsEveryCell() throws {
    let base = try grid(makeFrame(luma: 200))
    let dark = try grid(makeFrame(luma: 20))
    #expect(base.changedCells(comparedTo: dark) == LumaGridSignature.columns * LumaGridSignature.rows)
  }

  @Test func toleranceMapsSettingToChangedCells() {
    #expect(LumaGridSignature.toleratedChangedCells(forSensitivity: -3) == 0)
    #expect(LumaGridSignature.toleratedChangedCells(forSensitivity: 0) == 0)
    #expect(LumaGridSignature.toleratedChangedCells(forSensitivity: 3) == 0)
    #expect(LumaGridSignature.toleratedChangedCells(forSensitivity: SettingsStore.defaultDedupHammingThreshold) == 1)
    #expect(LumaGridSignature.toleratedChangedCells(forSensitivity: 16) == 4)
  }

  // MARK: - FrameOutput duplicate decision

  @Test func firstFrameIsNeverADuplicate() throws {
    let output = makeOutput()
    #expect(!output.skipsAsDuplicate(grid: try grid(makeFrame()), hash: 1, frontContext: "a", sensitivity: 6))
  }

  @Test func unchangedFrameInSameContextIsSkipped() throws {
    let output = makeOutput()
    output.lastGrid = try grid(makeFrame())
    output.lastFrontContext = "a"
    #expect(output.skipsAsDuplicate(grid: try grid(makeFrame()), hash: 0, frontContext: "a", sensitivity: 6))
  }

  @Test func defaultToleratesOneChangedCellButNotTwo() throws {
    let output = makeOutput()
    output.lastGrid = try grid(makeFrame())
    output.lastFrontContext = "a"
    let caret = try grid(makeFrame(patches: [cellPatch(5, 5)]))
    let typing = try grid(makeFrame(patches: [cellPatch(5, 5), cellPatch(6, 5)]))
    #expect(output.skipsAsDuplicate(grid: caret, hash: 0, frontContext: "a", sensitivity: 6))
    #expect(!output.skipsAsDuplicate(grid: typing, hash: 0, frontContext: "a", sensitivity: 6))
  }

  @Test func zeroToleranceCapturesAnyChangedCell() throws {
    let output = makeOutput()
    output.lastGrid = try grid(makeFrame())
    output.lastFrontContext = "a"
    #expect(!output.skipsAsDuplicate(grid: try grid(makeFrame(patches: [cellPatch(0, 0)])), hash: 0, frontContext: "a", sensitivity: 0))
  }

  @Test func contextChangeWithAnyVisibleChangeIsCaptured() throws {
    let output = makeOutput()
    output.lastGrid = try grid(makeFrame())
    output.lastFrontContext = "a"
    let changed = try grid(makeFrame(patches: [cellPatch(5, 5)]))
    #expect(!output.skipsAsDuplicate(grid: changed, hash: 0, frontContext: "b", sensitivity: 6))
    // Not skipped, so the baseline context is left for the persist path to update.
    #expect(output.lastFrontContext == "a")
  }

  @Test func titleOnlyChangeAdoptsNewContextSoToleranceReturns() throws {
    let output = makeOutput()
    output.lastGrid = try grid(makeFrame())
    output.lastFrontContext = "slack\u{1F}Slack"
    // The title changes ("(1) Slack") but the screen is identical: skipped, and adopted.
    #expect(output.skipsAsDuplicate(grid: try grid(makeFrame()), hash: 0, frontContext: "slack\u{1F}(1) Slack", sensitivity: 6))
    #expect(output.lastFrontContext == "slack\u{1F}(1) Slack")
    // A blinking caret afterwards no longer forces a capture.
    let caret = try grid(makeFrame(patches: [cellPatch(5, 5)]))
    #expect(output.skipsAsDuplicate(grid: caret, hash: 0, frontContext: "slack\u{1F}(1) Slack", sensitivity: 6))
  }

  @Test func firstContextAfterStartIsNotAContextChange() throws {
    let output = makeOutput()
    output.lastGrid = try grid(makeFrame())
    let caret = try grid(makeFrame(patches: [cellPatch(5, 5)]))
    #expect(output.skipsAsDuplicate(grid: caret, hash: 0, frontContext: "a", sensitivity: 6))
    #expect(output.lastFrontContext == "a")
  }

  @Test func fallsBackToHashWithoutGrid() {
    let output = makeOutput()
    output.lastHash = 0b0000
    output.lastFrontContext = "a"
    #expect(output.skipsAsDuplicate(grid: nil, hash: 0b0111, frontContext: "a", sensitivity: 6))
    #expect(!output.skipsAsDuplicate(grid: nil, hash: 0b0111, frontContext: "a", sensitivity: 2))
    #expect(!output.skipsAsDuplicate(grid: nil, hash: 0b0001, frontContext: "b", sensitivity: 6))
  }

  @Test func noBaselineMeansCapture() {
    let output = makeOutput()
    #expect(!output.skipsAsDuplicate(grid: nil, hash: 0, frontContext: "a", sensitivity: 16))
  }

  // MARK: - Saved setting

  private func isolatedDefaults() -> (UserDefaults, String) {
    let suite = "DuplicateDetectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  @Test func missingSettingUsesDefault() {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(SettingsStore.storedDedupThreshold(in: defaults) == SettingsStore.defaultDedupHammingThreshold)
  }

  @Test func savedZeroIsKept() {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(0, forKey: "settings.dedupHammingThreshold")
    #expect(SettingsStore.storedDedupThreshold(in: defaults) == 0)
  }

  @Test func savedValueIsKept() {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(16, forKey: "settings.dedupHammingThreshold")
    #expect(SettingsStore.storedDedupThreshold(in: defaults) == 16)
  }
}
