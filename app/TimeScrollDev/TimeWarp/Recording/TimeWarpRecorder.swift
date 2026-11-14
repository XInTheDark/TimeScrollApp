import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Records Time Warp context while it is on and screen capture runs. Everything happens on one
/// utility queue, separate from capture: a failure here only loses context. Reads are driven by
/// events (see `TimeWarpFocusObserver`), with two cheap backstops: a re-read when capture saves a
/// snapshot and the last read is over 30 s old (navigation that fired no notification). Spans are
/// written when they start and get their end when they close; after a crash, the one in progress
/// keeps no time.
final class TimeWarpRecorder: @unchecked Sendable {
  static let shared = TimeWarpRecorder()

  static let reconcileAfter: TimeInterval = 30
  /// Open items of an app are read on activation and deactivation, and at most this often otherwise.
  static let openItemsInterval: TimeInterval = 5 * 60
  static let openItemsMinimumGap: TimeInterval = 10
  /// Input idle longer than this is cut from the end of spans.
  static let idleThreshold: TimeInterval = 5 * 60
  static let loadRetryDelay: TimeInterval = 1

  private let queue = DispatchQueue(label: "TimeScroll.TimeWarp.Recorder", qos: .utility)
  private let store: TimeWarpSpanStore

  // State below is touched only on `queue`.
  private var tracker = TimeWarpSpanTracker()
  private let frontReader = TimeWarpFrontReader()
  private let openReader = TimeWarpOpenItemsReader()
  private var debounce = TimeWarpDebounce()
  private var readTimer: DispatchSourceTimer?
  private var running = false
  private var screenAvailable = true
  private var lastReadAt: TimeInterval = 0
  private var lastOpenReadAt: [String: TimeInterval] = [:]
  /// One retry per burst of events: a page that never gets an address must not be read forever.
  private var loadRetryUsed = false
  private var recordsOpenItems = false
  private var appleEventsAllowed: [String: Bool] = [:]

  // Main thread only.
  private var observer: TimeWarpFocusObserver?
  private var captureRunning = false
  private var settingsToken: NSObjectProtocol?
  private var accessibilityToken: NSObjectProtocol?

  init(store: TimeWarpSpanStore = DB.shared) {
    self.store = store
  }

  // MARK: Lifecycle (main thread)

  /// Screen capture started or stopped.
  func setCaptureRunning(_ isRunning: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    captureRunning = isRunning
    if settingsToken == nil {
      settingsToken = NotificationCenter.default.addObserver(forName: TimeWarpSettings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
        self?.refresh()
      }
      // Posted when any app's Accessibility permission changes; the new state is readable shortly after.
      accessibilityToken = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
      }
    }
    refresh()
  }

  /// Starts or stops recording to match the settings, capture and the Accessibility grant.
  func refresh() {
    dispatchPrecondition(condition: .onQueue(.main))
    let shouldRun = captureRunning && TimeWarpSettings.isEnabled() && AXIsProcessTrusted()
    if shouldRun {
      if observer == nil {
        let made = TimeWarpFocusObserver { [weak self] event in self?.handle(event) }
        observer = made
        queue.async { self.begin() }
        made.start()
      } else {
        queue.async { self.applySettings() }
      }
    } else if let observer {
      observer.stop()
      self.observer = nil
      queue.async { self.end() }
    }
  }

  /// Ends every span before the app quits.
  func stopNow() {
    dispatchPrecondition(condition: .onQueue(.main))
    observer?.stop()
    observer = nil
    queue.sync { self.end() }
  }

  /// Whether Warp points can be added now. Readable from any thread without waiting for a read.
  var isRecording: Bool {
    runningLock.lock()
    defer { runningLock.unlock() }
    return runningFlag
  }

  private let runningLock = NSLock()
  private var runningFlag = false

  private func setRunningFlag(_ value: Bool) {
    runningLock.lock()
    runningFlag = value
    runningLock.unlock()
  }

  /// The excluded apps changed: their spans end now.
  func exclusionsChanged() {
    queue.async {
      guard self.running else { return }
      self.closeExcludedSpans(endMs: Self.nowMs())
    }
  }

  /// Capture saved a snapshot; a cheap moment to catch up on missed changes.
  func snapshotCaptured() {
    queue.async {
      guard self.running else { return }
      if ProcessInfo.processInfo.systemUptime - self.lastReadAt > Self.reconcileAfter { self.readFront() }
    }
  }

  /// Records a note at `atMs`, the moment the user asked for it.
  func addWarpPoint(note: String, atMs: Int64, appBundleId: String?) {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    queue.async {
      guard self.running else { return }
      let item = TimeWarpItem(kind: .warpPoint, value: String(trimmed.prefix(500)))
      self.store.timeWarpRecordEvent(item, appBundleId: appBundleId, atMs: atMs)
      DispatchQueue.main.async { NotificationCenter.default.post(name: TimeWarpSettings.warpPointAddedNotification, object: nil) }
    }
  }

  // MARK: Recording (queue)

  private func begin() {
    guard !running else { return }
    running = true
    setRunningFlag(true)
    screenAvailable = true
    store.timeWarpCloseAbandonedSpans()
    applySettings()
    readFront()
  }

  private func end() {
    guard running else { return }
    apply(tracker.stopAll(endMs: idleAdjustedEndMs()))
    running = false
    setRunningFlag(false)
    recordsOpenItems = false
    readTimer?.cancel()
    readTimer = nil
    debounce = TimeWarpDebounce()
    lastOpenReadAt.removeAll()
    frontReader.iTermFolder = nil
    frontReader.forgetWindows()
    openReader.forgetWindows()
  }

  private func applySettings() {
    guard running else { return }
    let recordsOpen = TimeWarpSettings.recordsOpenItems()
    appleEventsAllowed.removeAll()
    if recordsOpen != recordsOpenItems {
      recordsOpenItems = recordsOpen
      if recordsOpen {
        readAllOpenItems()
      } else {
        for slot in tracker.openItemSlots {
          if case let .open(app, _) = slot { apply(tracker.closeOpenItems(appBundleId: app, endMs: Self.nowMs())) }
        }
      }
    }
    frontReader.iTermFolder = recordsOpen ? { [weak self] pid in
      guard let self, self.isAppleEventsAllowed(TimeWarpBrowserCatalog.iTermBundleId) else { return nil }
      return self.openReader.iTermFolder(pid: pid)
    } : nil
  }

  private func handle(_ event: TimeWarpFocusEvent) {
    queue.async {
      guard self.running else { return }
      switch event {
      case let .appActivated(_, bundleId), let .appDeactivated(_, bundleId):
        self.scheduleRead()
        if self.recordsOpenItems { self.readOpenItems(bundleId: bundleId, force: true) }
      case let .appTerminated(bundleId):
        self.apply(self.tracker.closeOpenItems(appBundleId: bundleId, endMs: Self.nowMs()))
        self.lastOpenReadAt[bundleId] = nil
        self.scheduleRead()
      case .windowChanged:
        self.scheduleRead()
      case .screenUnavailable:
        self.screenAvailable = false
        // Open items end too: a span must not stretch across a sleep longer than the span limit.
        self.apply(self.tracker.stopAll(endMs: self.idleAdjustedEndMs()))
        self.lastOpenReadAt.removeAll()
      case .screenAvailable:
        guard !self.screenAvailable else { return }
        self.screenAvailable = true
        self.scheduleRead()
        if self.recordsOpenItems { self.readAllOpenItems() }
      }
    }
  }

  private func scheduleRead() {
    loadRetryUsed = false
    let now = ProcessInfo.processInfo.systemUptime
    let due = debounce.note(at: now)
    readTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + max(0, due - now), leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.readTimer = nil
      if self.debounce.fire(at: ProcessInfo.processInfo.systemUptime) { self.readFront() }
    }
    timer.resume()
    readTimer = timer
  }

  private func readFront() {
    guard running, screenAvailable else { return }
    lastReadAt = ProcessInfo.processInfo.systemUptime
    let pid = AppActivityTracker.shared.currentProcessIdentifier
    let ownPid = ProcessInfo.processInfo.processIdentifier
    guard pid > 0, pid != ownPid, let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
      apply(tracker.pauseFront(endMs: idleAdjustedEndMs()))
      return
    }
    let observation = frontReader.read(pid: pid, bundleId: bundleId, excluded: TimeWarpSettings.excludedBundleIds())
    if observation.isBlocked {
      apply(tracker.pauseFront(endMs: idleAdjustedEndMs()))
      return
    }
    apply(tracker.observeFront(appBundleId: bundleId, item: observation.item, nowMs: Self.nowMs(), endMs: idleAdjustedEndMs()))
    // A page still loading has no address yet; look once more shortly.
    if observation.item == nil, TimeWarpBrowserCatalog.browser(forBundleId: bundleId) != nil, !loadRetryUsed {
      loadRetryUsed = true
      queue.asyncAfter(deadline: .now() + Self.loadRetryDelay) { [weak self] in self?.readFront() }
    }
    if recordsOpenItems { readOpenItems(bundleId: bundleId, force: false) }
  }

  private func readOpenItems(bundleId: String, force: Bool) {
    guard running, screenAvailable,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
          app.activationPolicy == .regular, bundleId != Bundle.main.bundleIdentifier else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let gap = force ? Self.openItemsMinimumGap : Self.openItemsInterval
    if let last = lastOpenReadAt[bundleId], now - last < gap { return }
    lastOpenReadAt[bundleId] = now
    guard let items = openReader.read(pid: app.processIdentifier, bundleId: bundleId,
                                      excluded: TimeWarpSettings.excludedBundleIds(),
                                      appleEventsAllowed: isAppleEventsAllowed(bundleId)) else { return }
    apply(tracker.replaceOpenItems(appBundleId: bundleId, items: items, nowMs: Self.nowMs()))
  }

  private func readAllOpenItems() {
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      if let bundleId = app.bundleIdentifier { readOpenItems(bundleId: bundleId, force: true) }
    }
  }

  private func isAppleEventsAllowed(_ bundleId: String) -> Bool {
    guard TimeWarpAppleEvents.supportedBundleIds.contains(bundleId) else { return false }
    if let known = appleEventsAllowed[bundleId] { return known }
    let allowed = TimeWarpAppleEvents.permission(bundleId: bundleId, askUser: false) == .allowed
    appleEventsAllowed[bundleId] = allowed
    return allowed
  }

  private func closeExcludedSpans(endMs: Int64) {
    apply(tracker.closeApps(TimeWarpSettings.excludedBundleIds(), endMs: endMs))
  }

  private func apply(_ actions: [TimeWarpSpanTracker.Action]) {
    guard !actions.isEmpty else { return }
    TimeWarpSpanWriter.apply(actions, to: &tracker, store: store)
  }

  // MARK: Time

  static func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  /// Now, or the last input if the user has been away longer than `idleThreshold`.
  private func idleAdjustedEndMs() -> Int64 {
    let anyInput = CGEventType(rawValue: ~0)!
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    let now = Self.nowMs()
    guard idle.isFinite, idle > Self.idleThreshold else { return now }
    return now - Int64(idle * 1000)
  }
}
