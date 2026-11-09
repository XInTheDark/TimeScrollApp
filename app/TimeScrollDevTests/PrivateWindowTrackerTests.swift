import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimeScroll

struct PrivateWindowTrackerTests {
  private static let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
  private static let otherDisplay = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
  private static let pid: pid_t = 42

  private final class StubReader: PrivateWindowEvidenceReading, @unchecked Sendable {
    var evidence: [CGWindowID: PrivateWindowEvidence] = [:]
    var calls = 0
    func evidence(pid: pid_t, profile: PrivateBrowsingProfile,
                  addressFieldWindows: Set<CGWindowID>) -> [CGWindowID: PrivateWindowEvidence] {
      calls += 1
      return evidence
    }
  }

  /// Runs classification when told to, so tests control the order of events.
  private final class Harness {
    var enabled = true
    var windows: [AXScreenWindow] = []
    var now: TimeInterval = 100
    var pending: [() -> Void] = []
    var refreshes = 0
    let reader = StubReader()
    lazy var tracker: PrivateWindowTracker = {
      let tracker = PrivateWindowTracker(isEnabled: { [unowned self] in enabled },
                                         windowList: { [unowned self] in windows },
                                         uptime: { [unowned self] in now },
                                         reader: reader,
                                         schedule: { [unowned self] work in pending.append(work) })
      tracker.setFilterStaleHandler { [unowned self] in refreshes += 1 }
      tracker.updateBrowsers([PrivateWindowTrackerTests.pid: PrivateBrowsingCatalog.profile(forBundleId: "com.google.Chrome")!])
      return tracker
    }()

    func runClassification() {
      let work = pending
      pending = []
      work.forEach { $0() }
    }

    func drop(on display: CGRect = PrivateWindowTrackerTests.display, pts: Double = 1000) -> Bool {
      tracker.shouldDrop(framePTS: CMTime(seconds: pts, preferredTimescale: 600), displayBounds: display)
    }

    /// What CaptureManager does after a stale signal.
    func applyFilter(at seconds: Double = 500) {
      let plan = tracker.filterPlan(listedPIDs: [PrivateWindowTrackerTests.pid])
      tracker.filterApplied(plan, at: CMTime(seconds: seconds, preferredTimescale: 600))
    }
  }

  private func window(_ id: CGWindowID, _ bounds: CGRect = CGRect(x: 10, y: 10, width: 500, height: 500)) -> AXScreenWindow {
    AXScreenWindow(id: id, pid: Self.pid, layer: 0, alpha: 1, bounds: bounds)
  }

  private func standard(_ title: String) -> PrivateWindowEvidence {
    PrivateWindowEvidence(title: title, subrole: "AXStandardWindow", hasCloseButton: true)
  }

  private let privateTitle = "Page - Google Chrome (Incognito)"
  private let normalTitle = "Page - Google Chrome"

  @Test func newWindowHoldsFramesUntilItIsNormal() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(normalTitle)]
    #expect(h.drop())
    h.runClassification()
    #expect(!h.drop())
    #expect(h.refreshes == 0)
  }

  @Test func privateWindowHoldsFramesUntilTheFilterCoversIt() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    #expect(h.drop())
    h.runClassification()
    #expect(h.refreshes == 1)
    #expect(h.drop())
    h.applyFilter()
    #expect(!h.drop())
  }

  @Test func framesFromBeforeTheFilterAreDropped() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter(at: 500)
    #expect(h.drop(pts: 499))
    #expect(!h.drop(pts: 501))
  }

  @Test func planExcludesTheBrowserAndExceptsItsNormalWindows() {
    let h = Harness()
    h.windows = [window(1), window(2), window(3)]
    h.reader.evidence = [
      1: standard(privateTitle),
      2: standard(normalTitle),
      3: PrivateWindowEvidence(title: "Translate this page?", subrole: "AXStandardWindow", hasCloseButton: false),
    ]
    _ = h.drop()
    h.runClassification()
    let plan = h.tracker.filterPlan(listedPIDs: [Self.pid])
    #expect(plan.browserPIDs == [Self.pid])
    #expect(plan.privateWindowIDs == [1])
    #expect(plan.exceptedWindowIDs == [2])
  }

  @Test func planIsEmptyWithoutPrivateWindowsSoNormalBrowsingKeepsItsFilter() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(normalTitle)]
    _ = h.drop()
    h.runClassification()
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]) == .empty)
  }

  @Test func browserMissingFromTheListIsNotCountedAsCovered() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    let plan = h.tracker.filterPlan(listedPIDs: [])
    #expect(plan == .empty)
    h.tracker.filterApplied(plan, at: .zero)
    #expect(h.drop())
  }

  @Test func privateVerdictIsNeverDowngraded() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    // A dialog replaced the title, and the recheck sees no marker.
    h.reader.evidence = [1: standard("Save file")]
    h.now += PrivateWindowTracker.recheckInterval
    _ = h.drop()
    h.runClassification()
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]).privateWindowIDs == [1])
  }

  @Test func recheckCatchesAMarkerThatAppearsLater() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard("Save file")]
    _ = h.drop()
    h.runClassification()
    #expect(!h.drop())
    h.reader.evidence = [1: standard(privateTitle)]
    h.now += PrivateWindowTracker.recheckInterval
    _ = h.drop()
    h.runClassification()
    #expect(h.refreshes == 1)
    #expect(h.drop())
  }

  @Test func undecidedWindowStopsHoldingFramesAfterTheGrace() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [:]
    #expect(h.drop())
    h.runClassification()
    h.now += PrivateWindowTracker.undeterminedGrace
    #expect(!h.drop())
    #expect(!h.tracker.hidesText(of: window(1)))
  }

  @Test(arguments: [nil, ""] as [String?])
  func filteredUndecidedTextStaysHiddenAfterTheGrace(title: String?) {
    let h = Harness()
    h.windows = [window(1, Self.otherDisplay), window(2)]
    h.reader.evidence = [
      1: standard(privateTitle),
      2: PrivateWindowEvidence(title: title, subrole: "AXStandardWindow", hasCloseButton: true),
    ]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.now += PrivateWindowTracker.undeterminedGrace
    #expect(!h.drop())
    #expect(h.tracker.hidesText(of: window(2)))
    let planned = AXWindowPlanner.plan(windows: h.windows, displayBounds: Self.display, maxWindows: 16) {
      h.tracker.hidesText(of: $0)
    }
    #expect(planned.isEmpty)
  }

  @Test func newlyNormalTextWaitsForItsFilterException() {
    let h = Harness()
    h.windows = [window(1, Self.otherDisplay), window(2)]
    h.reader.evidence = [1: standard(privateTitle), 2: standard("")]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.reader.evidence[2] = standard(normalTitle)
    h.now += PrivateWindowTracker.recheckInterval
    _ = h.drop()
    h.runClassification()
    #expect(h.tracker.hidesText(of: window(2)))
    #expect(!h.drop())
    h.applyFilter()
    #expect(!h.tracker.hidesText(of: window(2)))
    let planned = AXWindowPlanner.plan(windows: h.windows, displayBounds: Self.display, maxWindows: 16) {
      h.tracker.hidesText(of: $0)
    }
    #expect(planned.map(\.window.id) == [2])
  }

  @Test(arguments: [false, true])
  func auxiliaryWindowWaitsForItsPrivateBrowserFilter(parentMinimised: Bool) {
    let h = Harness()
    h.windows = [window(1, Self.otherDisplay), window(2)]
    h.reader.evidence = [
      1: standard(privateTitle),
      2: PrivateWindowEvidence(title: "Bubble", subrole: "AXStandardWindow", hasCloseButton: false),
    ]
    _ = h.drop()
    h.runClassification()
    if parentMinimised { h.windows = [window(2)] }
    h.now += PrivateWindowTracker.undeterminedGrace
    #expect(h.drop())
    #expect(h.tracker.hidesText(of: window(2)))
    let planned = AXWindowPlanner.plan(windows: h.windows, displayBounds: Self.display, maxWindows: 16) {
      h.tracker.hidesText(of: $0)
    }
    #expect(planned.isEmpty)
    h.tracker.filterApplied(h.tracker.filterPlan(listedPIDs: []), at: .zero)
    #expect(h.drop())
    #expect(h.tracker.hidesText(of: window(2)))
    h.applyFilter(at: 500)
    #expect(h.drop(pts: 499))
    #expect(!h.drop(pts: 501))
    #expect(h.tracker.hidesText(of: window(2)))
  }

  @Test func auxiliaryWindowWithoutAPrivateBrowserRemainsAllowed() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: PrivateWindowEvidence(title: "Bubble", subrole: "AXStandardWindow", hasCloseButton: false)]
    _ = h.drop()
    h.runClassification()
    #expect(!h.drop())
    #expect(!h.tracker.hidesText(of: window(1)))
  }

  @Test func anotherBrowsersAuxiliaryWindowRemainsAllowed() {
    let h = Harness()
    let profile = PrivateBrowsingCatalog.profile(forBundleId: "com.google.Chrome")!
    h.tracker.updateBrowsers([Self.pid: profile, 43: profile])
    let popup = AXScreenWindow(id: 2, pid: 43, layer: 0, alpha: 1, bounds: Self.display)
    h.windows = [window(1, Self.otherDisplay), popup]
    h.reader.evidence = [
      1: standard(privateTitle),
      2: PrivateWindowEvidence(title: "Bubble", subrole: "AXStandardWindow", hasCloseButton: false),
    ]
    _ = h.drop()
    h.runClassification()
    #expect(!h.drop())
    #expect(!h.tracker.hidesText(of: popup))
  }

  @Test(arguments: [false, true])
  func removedNormalExceptionDropsBufferedFrames(undecided: Bool) {
    let h = Harness()
    h.windows = [window(1, Self.otherDisplay), window(2)]
    h.reader.evidence = [1: standard(privateTitle), 2: standard(normalTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter(at: 500)
    #expect(!h.tracker.hidesText(of: window(2)))
    h.reader.evidence[2] = undecided ? standard("") :
      PrivateWindowEvidence(title: "Bubble", subrole: "AXStandardWindow", hasCloseButton: false)
    h.now += PrivateWindowTracker.recheckInterval
    _ = h.drop()
    h.runClassification()
    #expect(h.drop(pts: 800))
    #expect(h.tracker.hidesText(of: window(2)))
    h.applyFilter(at: 900)
    #expect(h.drop(pts: 899))
    #expect(!h.drop(pts: 901))
    #expect(h.tracker.hidesText(of: window(2)))
  }

  @Test func windowMissingFromAccessibilityBecomesAuxiliaryOnlyAfterTheDelay() {
    let h = Harness()
    h.windows = [window(1), window(2)]
    h.reader.evidence = [2: standard(normalTitle)]
    #expect(h.drop())
    h.runClassification()
    #expect(h.drop())
    h.now += PrivateWindowTracker.auxiliaryDelay
    #expect(h.drop())
    h.runClassification()
    #expect(!h.drop())
  }

  @Test func windowOnAnotherDisplayDoesNotHoldThisDisplay() {
    let h = Harness()
    h.windows = [window(1, CGRect(x: 1100, y: 10, width: 500, height: 500))]
    #expect(!h.drop(on: Self.display))
    #expect(h.drop(on: Self.otherDisplay))
  }

  @Test func concurrentFramesQueueOneReadPerBrowser() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(normalTitle)]
    _ = h.drop()
    _ = h.drop()
    #expect(h.pending.count == 1)
  }

  @Test func disabledDoesNothing() {
    let h = Harness()
    h.enabled = false
    h.windows = [window(1)]
    #expect(!h.drop())
    #expect(h.pending.isEmpty)
    #expect(!h.tracker.hidesText(of: window(1)))
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]) == .empty)
  }

  @Test func withNoBrowserRunningTheWindowListIsNotRead() {
    var reads = 0
    let tracker = PrivateWindowTracker(isEnabled: { true }, windowList: { reads += 1; return [] }, reader: StubReader(), schedule: { _ in })
    #expect(!tracker.shouldDrop(framePTS: CMTime(seconds: 1, preferredTimescale: 600), displayBounds: Self.display))
    #expect(reads == 0)
  }

  @Test func directModeSkipsPrivateUnknownAndTheirPopups() {
    let h = Harness()
    h.windows = [window(1), window(2), window(3)]
    h.reader.evidence = [
      1: standard(privateTitle),
      2: standard(normalTitle),
      3: PrivateWindowEvidence(title: "Bubble", subrole: "AXStandardWindow", hasCloseButton: false),
    ]
    _ = h.drop()
    #expect(h.tracker.hidesText(of: window(1)))
    h.runClassification()
    h.applyFilter()
    #expect(h.tracker.hidesText(of: window(1)))
    #expect(!h.tracker.hidesText(of: window(2)))
    #expect(h.tracker.hidesText(of: window(3)))
    #expect(h.tracker.hidesText(of: window(99)))
    #expect(!h.tracker.hidesText(of: AXScreenWindow(id: 5, pid: 7, layer: 0, alpha: 1, bounds: .zero)))
  }

  @Test func closedPrivateWindowReleasesTheBrowser() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    h.now += PrivateWindowTracker.refreshInterval
    let refreshesBefore = h.refreshes
    #expect(!h.drop())
    #expect(h.refreshes == refreshesBefore + 1)
    h.tracker.retain(existing: [])
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]) == .empty)
  }

  @Test func releasingTheBrowserDoesNotFencePreviouslyFilteredFrames() {
    let h = Harness()
    h.windows = [window(1), window(2)]
    h.reader.evidence = [1: standard(privateTitle), 2: standard(normalTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter(at: 500)
    h.windows = [window(2)]
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    h.tracker.retain(existing: [2])
    h.applyFilter(at: 900)
    #expect(!h.drop(pts: 899))
    #expect(!h.tracker.hidesText(of: window(2)))
  }

  @Test func minimisedPrivateWindowStaysPrivate() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    _ = h.drop()
    h.tracker.retain(existing: [1])
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]).privateWindowIDs == [1])
  }

  @Test func closeInsideRefreshThrottleIsRetried() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    let before = h.refreshes
    _ = h.drop()
    #expect(h.refreshes == before)
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before + 1)
    _ = h.drop()
    _ = h.drop(on: Self.otherDisplay)
    #expect(h.refreshes == before + 1)
  }

  @Test func failedCloseEnumerationKeepsRequestingReconciliation() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    let before = h.refreshes
    for attempt in 1...3 {
      h.now += PrivateWindowTracker.refreshInterval
      #expect(!h.drop())
      #expect(h.refreshes == before + attempt)
      // Simulate shareableContent throwing: no retain or filterApplied callback.
    }
    h.tracker.retain(existing: [])
    h.applyFilter()
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before + 3)
  }

  @Test func minimisedThenClosedPrivateWindowIsReconciled() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    h.tracker.retain(existing: [1])
    h.applyFilter()
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]).privateWindowIDs == [1])
    let before = h.refreshes
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before)
    h.now += PrivateWindowTracker.recheckInterval - PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before + 1)
    h.tracker.retain(existing: [])
    h.applyFilter()
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]) == .empty)
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before + 1)
  }

  @Test func failedFilterReleaseKeepsRequestingReconciliationAfterEntryRemoval() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    h.tracker.retain(existing: [])
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]) == .empty)
    // Simulate updateContentFilter failing: the previous applied plan remains.
    let before = h.refreshes
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before + 1)
    #expect(h.tracker.hidesText(of: window(1)))
    h.applyFilter()
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before + 1)
  }

  @Test func returningPrivateWindowNeedsANewExistenceCheckWhenMinimisedAgain() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    h.tracker.retain(existing: [1])
    h.applyFilter()
    h.windows = [window(1)]
    _ = h.drop()
    h.windows = []
    h.now += PrivateWindowTracker.refreshInterval
    let before = h.refreshes
    _ = h.drop()
    #expect(h.refreshes == before + 1)
  }

  @Test func minimisedWindowChecksAreBoundedAndRetryAfterAFailedRecheck() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.applyFilter()
    h.windows = []
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    h.tracker.retain(existing: [1])
    h.applyFilter()
    let checkedAt = h.now
    let before = h.refreshes
    for tick in 0..<150 {
      h.now = checkedAt + Double(tick) / 10
      _ = h.drop()
      _ = h.drop(on: Self.otherDisplay)
    }
    #expect(h.refreshes == before)
    h.now = checkedAt + PrivateWindowTracker.recheckInterval
    _ = h.drop()
    #expect(h.refreshes == before + 1)
    // The periodic existence check fails: retry at the short refresh interval.
    h.now += PrivateWindowTracker.refreshInterval
    _ = h.drop()
    #expect(h.refreshes == before + 2)
  }

  @Test func quitBrowserRetriesFailedFilterReleaseWithoutReadingTheWindowList() {
    var now: TimeInterval = 100
    var reads = 0
    var refreshes = 0
    let tracker = PrivateWindowTracker(isEnabled: { true }, windowList: { reads += 1; return [] },
                                       uptime: { now }, reader: StubReader(), schedule: { _ in })
    let plan = PrivateWindowFilterPlan(windows: [(id: 1, pid: Self.pid, verdict: .privateWindow)])
    tracker.filterApplied(plan, at: .zero)
    tracker.setFilterStaleHandler { refreshes += 1 }
    #expect(!tracker.shouldDrop(framePTS: .zero, displayBounds: Self.display))
    #expect(refreshes == 1)
    #expect(tracker.hidesText(of: window(1)))
    now += PrivateWindowTracker.refreshInterval
    _ = tracker.shouldDrop(framePTS: .zero, displayBounds: Self.display)
    #expect(refreshes == 2)
    tracker.filterApplied(.empty, at: .zero)
    now += PrivateWindowTracker.refreshInterval
    _ = tracker.shouldDrop(framePTS: .zero, displayBounds: Self.display)
    #expect(refreshes == 2)
    #expect(reads == 0)
    #expect(!tracker.hidesText(of: window(1)))
  }

  @Test func quitBrowserIsForgotten() {
    let h = Harness()
    h.windows = [window(1)]
    h.reader.evidence = [1: standard(privateTitle)]
    _ = h.drop()
    h.runClassification()
    h.tracker.updateBrowsers([:])
    #expect(h.tracker.filterPlan(listedPIDs: [Self.pid]) == .empty)
    #expect(!h.tracker.hidesText(of: window(1)))
  }
}
