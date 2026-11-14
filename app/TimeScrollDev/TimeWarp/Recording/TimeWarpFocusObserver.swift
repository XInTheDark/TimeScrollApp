import AppKit
import ApplicationServices
import Foundation

/// What can change the front context.
enum TimeWarpFocusEvent: Equatable {
  case appActivated(pid: pid_t, bundleId: String)
  case appDeactivated(pid: pid_t, bundleId: String)
  case appTerminated(bundleId: String)
  /// The front app's focused window, its title, or its contents changed.
  case windowChanged(pid: pid_t)
  /// Sleep, screen lock, screensaver or a switch to another user: nothing is in front.
  case screenUnavailable
  case screenAvailable
}

/// Reports focus changes without polling: workspace and system notifications, plus Accessibility
/// notifications from the front app. Accessibility observers run on their own thread, so a hung app
/// cannot hold up the main thread; callbacks only forward the event.
final class TimeWarpFocusObserver {
  static let windowNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                                    kAXTitleChangedNotification, kAXUIElementDestroyedNotification]

  private let handler: (TimeWarpFocusEvent) -> Void
  private var workspaceTokens: [NSObjectProtocol] = []
  private var distributedTokens: [NSObjectProtocol] = []
  private let axThread = TimeWarpRunLoopThread(name: "TimeScroll.TimeWarp.AXObserver")
  // Touched only on `axThread`.
  private var observer: AXObserver?
  private var observedPid: pid_t = 0

  init(handler: @escaping (TimeWarpFocusEvent) -> Void) {
    self.handler = handler
  }

  deinit {
    // `stop()` normally ran already; this only makes sure the thread cannot outlive the observer.
    axThread.finish()
  }

  /// Call on the main thread.
  func start() {
    guard workspaceTokens.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    let ownBundleId = Bundle.main.bundleIdentifier
    func app(_ note: Notification) -> NSRunningApplication? {
      note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }
    workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      guard let self, let app = app(note), let bundleId = app.bundleIdentifier else { return }
      self.observe(pid: bundleId == ownBundleId ? 0 : app.processIdentifier)
      self.handler(.appActivated(pid: app.processIdentifier, bundleId: bundleId))
    })
    workspaceTokens.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      guard let app = app(note), let bundleId = app.bundleIdentifier else { return }
      self?.handler(.appDeactivated(pid: app.processIdentifier, bundleId: bundleId))
    })
    workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      guard let bundleId = app(note)?.bundleIdentifier else { return }
      self?.handler(.appTerminated(bundleId: bundleId))
    })
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.handler(.screenUnavailable)
      })
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.handler(.screenAvailable)
      })
    }
    let distributed = DistributedNotificationCenter.default()
    for (name, event) in [("com.apple.screenIsLocked", TimeWarpFocusEvent.screenUnavailable),
                          ("com.apple.screensaver.didstart", .screenUnavailable),
                          ("com.apple.screenIsUnlocked", .screenAvailable),
                          ("com.apple.screensaver.didstop", .screenAvailable)] {
      distributedTokens.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
        self?.handler(event)
      })
    }
    axThread.start()
    if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != ownBundleId {
      observe(pid: front.processIdentifier)
    }
  }

  /// Call on the main thread.
  func stop() {
    workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    workspaceTokens.removeAll()
    distributedTokens.forEach(DistributedNotificationCenter.default().removeObserver)
    distributedTokens.removeAll()
    // Holds the observer until it has detached, so no callback can reach a released observer;
    // then the thread's run loop ends and the thread exits.
    axThread.perform { [self] in self.detach() }
    axThread.finish()
  }

  private func observe(pid: pid_t) {
    axThread.perform { [weak self] in
      guard let self, pid != self.observedPid else { return }
      self.detach()
      guard pid > 0 else { return }
      self.attach(pid: pid)
    }
  }

  private func attach(pid: pid_t) {
    var made: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      let me = Unmanaged<TimeWarpFocusObserver>.fromOpaque(refcon).takeUnretainedValue()
      me.handler(.windowChanged(pid: me.observedPid))
    }
    guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, TimeWarpWindowReader.messagingTimeout)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in Self.windowNotifications {
      _ = AXObserverAddNotification(made, app, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(made), .defaultMode)
    observer = made
    observedPid = pid
  }

  private func detach() {
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    observer = nil
    observedPid = 0
  }
}
