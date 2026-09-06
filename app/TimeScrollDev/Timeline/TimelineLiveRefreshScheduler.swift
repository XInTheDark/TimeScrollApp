import AppKit
import Combine

@MainActor
final class TimelineLiveRefreshScheduler: ObservableObject {
  var refresh: () -> Void = {}
  var isReady: () -> Bool = { true }
  var isEnabled: () -> Bool = { true }
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []
  private var pending: Task<Void, Never>?
  private var dirty = false
  private var lastRefresh: TimeInterval = -.infinity
  private let interval: TimeInterval

  init(interval: TimeInterval = 1) { self.interval = interval }

  func attach(to window: NSWindow?) {
    guard window == nil || self.window !== window else { return }
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    self.window = window
    if let window {
      for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.visibilityChanged() }
        })
      }
      for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.visibilityChanged() }
        })
      }
    }
    visibilityChanged()
  }

  private var visible: Bool {
    guard let window else { return false }
    return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && !NSApp.isHidden
  }

  func notify() {
    guard isEnabled() else { return }
    dirty = true
    schedule()
  }

  private func visibilityChanged() {
    if !visible { pending?.cancel(); pending = nil }
    schedule()
  }

  private func schedule() {
    guard dirty, visible, pending == nil else { return }
    let delay = max(isReady() ? 0 : interval, interval - (ProcessInfo.processInfo.systemUptime - lastRefresh))
    pending = Task { @MainActor [weak self] in
      if delay > 0 {
        do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
      }
      guard !Task.isCancelled, let self else { return }
      self.pending = nil
      guard self.visible else { return }
      guard self.isEnabled() else { self.dirty = false; return }
      guard self.isReady() else { self.schedule(); return }
      self.dirty = false
      self.lastRefresh = ProcessInfo.processInfo.systemUptime
      self.refresh()
    }
  }
}
