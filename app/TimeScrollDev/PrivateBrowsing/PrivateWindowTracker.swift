import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation

/// Tracks the windows of running browsers and decides what capture may see. It only reads the window
/// list on evaluated frames, and Accessibility runs on its own queue, so the capture queue never waits
/// on a browser. If detection cannot decide and no private window is known in that browser, frames
/// resume after `undeterminedGrace`: a detection failure must not stop capture for long.
final class PrivateWindowTracker: @unchecked Sendable {
  static let shared = PrivateWindowTracker()

  /// Without a known private window in its browser, an undecided window holds frames this long.
  static let undeterminedGrace: TimeInterval = 3
  /// A window missing from Accessibility may just be new. After this long it counts as a popup.
  static let auxiliaryDelay: TimeInterval = 0.5
  /// Rechecks late markers and the existence of private windows that stay off screen this often.
  static let recheckInterval: TimeInterval = 15
  static let refreshInterval: TimeInterval = 1
  /// A normal window off screen for this long is forgotten; it is checked again if it returns.
  static let forgetInterval: TimeInterval = 300

  private struct Entry {
    let pid: pid_t
    let firstSeen: TimeInterval
    var lastOnScreen: TimeInterval
    var isOnScreen = true
    var lastExistenceCheck: TimeInterval?
    var verdict = PrivateWindowVerdict.undetermined
    var addressFieldChecked = false
  }

  private let lock = NSLock()
  private var browsers: [pid_t: PrivateBrowsingProfile] = [:]
  private var entries: [CGWindowID: Entry] = [:]
  private var inFlight: Set<pid_t> = []
  private var lastSweep: [pid_t: TimeInterval] = [:]
  private var applied = PrivateWindowFilterPlan.empty
  private var filterChangedAt: CMTime = .zero
  private var lastRefreshRequest: TimeInterval?
  private var filterStaleHandler: (() -> Void)?

  private let isEnabled: () -> Bool
  private let windowList: () -> [AXScreenWindow]
  private let uptime: () -> TimeInterval
  private let reader: PrivateWindowEvidenceReading
  private let schedule: (@escaping () -> Void) -> Void

  init(isEnabled: @escaping () -> Bool = PrivateWindowTracker.liveIsEnabled,
       windowList: @escaping () -> [AXScreenWindow] = ExcludedAppGate.liveWindowList,
       uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       reader: PrivateWindowEvidenceReading = LivePrivateWindowEvidenceReader(),
       schedule: ((@escaping () -> Void) -> Void)? = nil) {
    self.isEnabled = isEnabled
    self.windowList = windowList
    self.uptime = uptime
    self.reader = reader
    if let schedule {
      self.schedule = schedule
    } else {
      let queue = DispatchQueue(label: "TimeScroll.PrivateWindows", qos: .utility)
      nonisolated(unsafe) let run: (@escaping () -> Void) -> Void = { work in
        nonisolated(unsafe) let work = work
        queue.async { work() }
      }
      self.schedule = run
    }
  }

  static func liveIsEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: SettingsStore.excludePrivateWindowsKey) && AXIsProcessTrusted()
  }

  func setFilterStaleHandler(_ handler: (() -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    filterStaleHandler = handler
  }

  /// The running browsers to watch. Browsers that quit are forgotten.
  func updateBrowsers(_ running: [pid_t: PrivateBrowsingProfile]) {
    lock.lock()
    defer { lock.unlock() }
    browsers = running
    entries = entries.filter { running[$0.value.pid] != nil }
    lastSweep = lastSweep.filter { running[$0.key] != nil }
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    browsers = [:]
    entries = [:]
    inFlight = []
    lastSweep = [:]
    applied = .empty
    filterChangedAt = .zero
    lastRefreshRequest = nil
  }

  // MARK: - Capture path

  /// Whether this frame could show a private window the filter does not cover yet.
  func shouldDrop(framePTS: CMTime, displayBounds: CGRect) -> Bool {
    lock.lock()
    let changedAt = filterChangedAt
    let hasBrowsers = !browsers.isEmpty
    let hadApplied = !applied.browserPIDs.isEmpty
    lock.unlock()
    guard hasBrowsers || hadApplied else { return false }
    guard isEnabled() else { return false }
    if CMTimeCompare(framePTS, changedAt) < 0 { return true }
    guard hasBrowsers else {
      requestRefreshIfDue(now: uptime())
      return false
    }

    let windows = windowList()
    let now = uptime()
    lock.lock()
    let visible = windows.filter { browsers[$0.pid] != nil && ExcludedAppGate.isContentWindow($0) }
    var drop = false
    var filterStale = false
    var toClassify: Set<pid_t> = []
    let onScreenIDs = Set(visible.map(\.id))
    var privateBrowserPIDs: Set<pid_t> = []

    for (id, entry) in entries {
      if !onScreenIDs.contains(id) {
        if entry.isOnScreen { entries[id]?.isOnScreen = false }
      } else if entry.lastExistenceCheck != nil {
        entries[id]?.lastExistenceCheck = nil
      }
      if entry.verdict == .privateWindow {
        privateBrowserPIDs.insert(entry.pid)
        // Offscreen windows may be minimised, then closed without another onscreen transition.
        let needsExistenceCheck = !onScreenIDs.contains(id) &&
          (entry.lastExistenceCheck.map { now - $0 >= Self.recheckInterval } ?? true)
        if !applied.privateWindowIDs.contains(id) || needsExistenceCheck { filterStale = true }
      }
    }
    // retain(existing:) can remove a closed entry before a filter update fails. Keep retrying.
    if applied.privateWindowIDs.contains(where: { entries[$0]?.verdict != .privateWindow }) {
      filterStale = true
    }
    entries = entries.filter { _, entry in
      if entry.isOnScreen || entry.verdict == .privateWindow { return true }
      return entry.verdict == .normal && now - entry.lastOnScreen < Self.forgetInterval
    }

    for window in visible {
      let onDisplay = window.bounds.intersects(displayBounds)
      if entries[window.id] == nil {
        entries[window.id] = Entry(pid: window.pid, firstSeen: now, lastOnScreen: now)
      }
      entries[window.id]?.isOnScreen = true
      entries[window.id]?.lastOnScreen = now
      guard let entry = entries[window.id] else { continue }
      switch entry.verdict {
      case .privateWindow:
        if !applied.privateWindowIDs.contains(window.id) {
          filterStale = true
          if onDisplay { drop = true }
        }
      case .normal:
        // Hidden by the browser's exclusion until a rebuilt filter lets it back in.
        if applied.browserPIDs.contains(window.pid), !applied.exceptedWindowIDs.contains(window.id) {
          filterStale = true
        }
      case .auxiliary, .undetermined:
        if privateBrowserPIDs.contains(window.pid),
           !applied.browserPIDs.contains(window.pid) || applied.exceptedWindowIDs.contains(window.id) {
          filterStale = true
          if onDisplay { drop = true }
        }
        if entry.verdict == .undetermined, now - entry.firstSeen < Self.undeterminedGrace {
          toClassify.insert(window.pid)
          if onDisplay { drop = true }
        }
      }
    }
    for pid in Set(visible.map(\.pid)) where now - (lastSweep[pid] ?? -.infinity) >= Self.recheckInterval {
      toClassify.insert(pid)
    }
    let jobs = toClassify.subtracting(inFlight)
    for pid in jobs { lastSweep[pid] = now }
    inFlight.formUnion(jobs)
    let requests = jobs.compactMap { pid in browsers[pid].map { (pid, $0, addressFieldWindows(of: pid, profile: $0)) } }
    lock.unlock()

    for (pid, profile, addressFields) in requests {
      schedule { [self] in classify(pid: pid, profile: profile, addressFieldWindows: addressFields) }
    }
    if filterStale { requestRefreshIfDue(now: now) }
    return drop
  }

  /// Whether Direct mode must leave this window's text alone, which needs no Accessibility call here.
  func hidesText(of window: AXScreenWindow) -> Bool {
    guard isEnabled() else { return false }
    let now = uptime()
    lock.lock()
    defer { lock.unlock() }
    if applied.browserPIDs.contains(window.pid), !applied.exceptedWindowIDs.contains(window.id) {
      return true
    }
    guard browsers[window.pid] != nil else { return false }
    // Not seen on a frame yet, so nothing is known about it.
    guard let entry = entries[window.id] else { return true }
    switch entry.verdict {
    case .privateWindow: return true
    case .normal: return false
    case .auxiliary, .undetermined:
      if entries.values.contains(where: { $0.pid == window.pid && $0.verdict == .privateWindow }) { return true }
      return entry.verdict == .undetermined && now - entry.firstSeen < Self.undeterminedGrace
    }
  }

  // MARK: - Filter

  /// Limited to the apps ScreenCaptureKit lists, because a filter can only exclude those.
  func filterPlan(listedPIDs: Set<pid_t>) -> PrivateWindowFilterPlan {
    guard isEnabled() else { return .empty }
    lock.lock()
    defer { lock.unlock() }
    return PrivateWindowFilterPlan(windows: entries.filter { listedPIDs.contains($0.value.pid) }.map {
      (id: $0.key, pid: $0.value.pid, verdict: $0.value.verdict)
    })
  }

  /// Forgets private windows that no longer exist, given every window ScreenCaptureKit lists.
  func retain(existing ids: Set<CGWindowID>) {
    let now = uptime()
    lock.lock()
    defer { lock.unlock() }
    entries = entries.filter { $0.value.isOnScreen || ids.contains($0.key) }
    for (id, entry) in entries where entry.verdict == .privateWindow && !entry.isOnScreen {
      entries[id]?.lastExistenceCheck = now
    }
  }

  /// Records what the filters now do. Frames before `time` may predate a newly excluded window.
  func filterApplied(_ plan: PrivateWindowFilterPlan, at time: CMTime) {
    lock.lock()
    defer { lock.unlock() }
    let removesExceptions = !plan.browserPIDs.isEmpty && !applied.exceptedWindowIDs.isSubset(of: plan.exceptedWindowIDs)
    if !plan.privateWindowIDs.isSubset(of: applied.privateWindowIDs) || removesExceptions { filterChangedAt = time }
    applied = plan
  }

  // MARK: - Classification

  private func addressFieldWindows(of pid: pid_t, profile: PrivateBrowsingProfile) -> Set<CGWindowID> {
    guard profile.addressField != nil else { return [] }
    return Set(entries.filter { $0.value.pid == pid && !$0.value.addressFieldChecked }.keys)
  }

  private func classify(pid: pid_t, profile: PrivateBrowsingProfile, addressFieldWindows: Set<CGWindowID>) {
    let evidence = reader.evidence(pid: pid, profile: profile, addressFieldWindows: addressFieldWindows)
    let now = uptime()
    lock.lock()
    inFlight.remove(pid)
    var filterStale = false
    for (id, entry) in entries where entry.pid == pid && entry.verdict != .privateWindow {
      if let found = evidence[id] {
        entries[id]?.verdict = PrivateWindowClassifier.verdict(for: found, profile: profile)
        if found.addressFieldDescription != nil { entries[id]?.addressFieldChecked = true }
      } else if !evidence.isEmpty, now - entry.firstSeen >= Self.auxiliaryDelay {
        entries[id]?.verdict = .auxiliary
      }
      if entries[id]?.verdict == .privateWindow { filterStale = true }
    }
    lock.unlock()
    if filterStale { requestRefreshIfDue(now: now) }
  }

  private func requestRefreshIfDue(now: TimeInterval) {
    lock.lock()
    let isDue = lastRefreshRequest.map { now - $0 >= Self.refreshInterval } ?? true
    if isDue { lastRefreshRequest = now }
    let handler = filterStaleHandler
    lock.unlock()
    if isDue { handler?() }
  }
}
