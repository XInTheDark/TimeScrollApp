import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimeScroll

@Suite struct ExcludedAppGateTests {
  private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
  private let frame = CMTime(seconds: 100, preferredTimescale: 600)

  private final class Probe: @unchecked Sendable {
    var windows: [AXScreenWindow] = []
    var listCalls = 0
    var refreshes = 0
    var now: TimeInterval = 0
  }

  private func window(pid: pid_t, layer: Int = 0, alpha: Double = 1,
                      bounds: CGRect = CGRect(x: 10, y: 10, width: 300, height: 200)) -> AXScreenWindow {
    AXScreenWindow(id: CGWindowID(pid), pid: pid, layer: layer, alpha: alpha, bounds: bounds)
  }

  private func makeGate(_ probe: Probe) -> ExcludedAppGate {
    ExcludedAppGate(
      windowList: { probe.listCalls += 1; return probe.windows },
      uptime: { probe.now },
      onRefreshNeeded: { probe.refreshes += 1 }
    )
  }

  @Test func noExcludedAppsCostsNoWindowList() {
    let probe = Probe()
    let gate = makeGate(probe)
    #expect(!gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(probe.listCalls == 0)
  }

  @Test func coveredAppsCostNoWindowList() {
    let probe = Probe()
    let gate = makeGate(probe)
    gate.updateCovered([1, 2], running: [1, 2], at: .zero)
    #expect(!gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(probe.listCalls == 0)
  }

  @Test func uncoveredAppWithVisibleWindowDropsAndRequestsRefresh() {
    let probe = Probe()
    probe.windows = [window(pid: 7)]
    let gate = makeGate(probe)
    gate.updateRunning([7])
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(probe.refreshes == 1)
  }

  @Test func uncoveredAppWithoutWindowsKeepsCapturing() {
    let probe = Probe()
    probe.windows = [window(pid: 99)]
    let gate = makeGate(probe)
    gate.updateRunning([7])
    #expect(!gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(probe.refreshes == 0)
  }

  @Test func windowOnAnotherDisplayOnlyDropsThatDisplay() {
    let probe = Probe()
    probe.windows = [window(pid: 7, bounds: CGRect(x: 1200, y: 0, width: 300, height: 200))]
    let gate = makeGate(probe)
    gate.updateRunning([7])
    #expect(!gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: CGRect(x: 1000, y: 0, width: 1000, height: 800)))
  }

  @Test func windowSpanningTwoDisplaysDropsBoth() {
    let probe = Probe()
    probe.windows = [window(pid: 7, bounds: CGRect(x: 900, y: 0, width: 300, height: 200))]
    let gate = makeGate(probe)
    gate.updateRunning([7])
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: CGRect(x: 1000, y: 0, width: 1000, height: 800)))
  }

  @Test func statusItemsAndInvisibleWindowsDoNotStopCapture() {
    let probe = Probe()
    probe.windows = [window(pid: 7, layer: 25), window(pid: 7, layer: -1), window(pid: 7, alpha: 0)]
    let gate = makeGate(probe)
    gate.updateRunning([7])
    #expect(!gate.shouldDrop(framePTS: frame, displayBounds: display))
  }

  @Test func refreshRequestsAreThrottledUntilTheIntervalPasses() {
    let probe = Probe()
    probe.windows = [window(pid: 7)]
    let gate = makeGate(probe)
    gate.updateRunning([7])
    _ = gate.shouldDrop(framePTS: frame, displayBounds: display)
    probe.now = 0.5
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(probe.refreshes == 1)
    probe.now = 1.0
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(probe.refreshes == 2)
  }

  @Test func framesResumeOnceTheFilterCoversTheApp() {
    let probe = Probe()
    probe.windows = [window(pid: 7)]
    let gate = makeGate(probe)
    gate.updateRunning([7])
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: display))
    gate.updateCovered([7], running: [7], at: frame)
    #expect(!gate.shouldDrop(framePTS: frame, displayBounds: display))
  }

  @Test func frameFromBeforeTheFilterGainedAnAppIsDropped() {
    let gate = makeGate(Probe())
    gate.updateCovered([7], running: [7], at: frame)
    let earlier = CMTime(seconds: 99, preferredTimescale: 600)
    #expect(gate.shouldDrop(framePTS: earlier, displayBounds: display))
  }

  @Test func removingAnAppDoesNotDropEarlierFrames() {
    let gate = makeGate(Probe())
    gate.updateCovered([7, 8], running: [7, 8], at: frame)
    gate.updateCovered([7], running: [7], at: CMTime(seconds: 200, preferredTimescale: 600))
    #expect(!gate.shouldDrop(framePTS: CMTime(seconds: 150, preferredTimescale: 600), displayBounds: display))
  }

  @Test func relaunchedAppIsUncoveredUnderItsNewPID() {
    let probe = Probe()
    probe.windows = [window(pid: 8)]
    let gate = makeGate(probe)
    gate.updateCovered([7], running: [7], at: .zero)
    gate.updateRunning([8])
    #expect(gate.shouldDrop(framePTS: frame, displayBounds: display))
  }

  @Test func quitAppStopsBeingChecked() {
    let probe = Probe()
    let gate = makeGate(probe)
    gate.updateRunning([7])
    gate.updateRunning([])
    #expect(!gate.shouldDrop(framePTS: frame, displayBounds: display))
    #expect(probe.listCalls == 0)
  }

  @Test func resetForgetsEverything() {
    let probe = Probe()
    probe.windows = [window(pid: 7)]
    let gate = makeGate(probe)
    gate.updateCovered([1], running: [1, 7], at: frame)
    gate.reset()
    #expect(!gate.shouldDrop(framePTS: .zero, displayBounds: display))
    #expect(probe.listCalls == 0)
  }
}
