import Testing
@testable import TimeScroll

struct SkippedHEVCFrameTests {
  private func makeOutput() -> FrameOutput {
    FrameOutput(onSnapshot: { _ in }, hevcStore: HEVCVideoStore(namespace: "skipped-hevc-tests"), displayBounds: .zero)
  }

  @Test func nothingToFlushBeforeAnySnapshot() {
    let output = makeOutput()
    #expect(output.skippedHEVCFrameAction() == .closeIfExpired)
  }

  @Test func onlyFirstSkippedFrameAfterSnapshotIsEncoded() {
    let output = makeOutput()
    output.needsHEVCFlushFrame = true
    #expect(output.skippedHEVCFrameAction() == .appendToFlush)
    #expect(output.skippedHEVCFrameAction() == .closeIfExpired)
    #expect(output.skippedHEVCFrameAction() == .closeIfExpired)
  }

  @Test func eachNewSnapshotGetsItsOwnFlushFrame() {
    let output = makeOutput()
    for _ in 0..<3 {
      output.needsHEVCFlushFrame = true
      #expect(output.skippedHEVCFrameAction() == .appendToFlush)
      #expect(output.skippedHEVCFrameAction() == .closeIfExpired)
    }
  }

  @Test func displaysTrackTheirOwnFlush() {
    let first = makeOutput()
    let second = makeOutput()
    first.needsHEVCFlushFrame = true
    #expect(second.skippedHEVCFrameAction() == .closeIfExpired)
    #expect(first.skippedHEVCFrameAction() == .appendToFlush)
  }
}
