import AppKit
import SwiftUI

extension AppDelegate {
  static let summarySetupShownKey = "settings.summarySetupShown"

  /// One time only, so it can't get in the way of anything later.
  func showSummarySetupIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.summarySetupShownKey) else { return }
    defaults.set(true, forKey: Self.summarySetupShownKey)
    let root = SummarySetupView(settings: SettingsStore.shared) { [weak self] in
      self?.summarySetupWC?.close()
      self?.summarySetupWC = nil
    }
    let window = NSWindow(contentViewController: NSHostingController(rootView: root))
    window.styleMask.insert([.titled, .closable])
    window.title = "TimeScroll"
    window.isReleasedWhenClosed = false
    window.center()
    let controller = NSWindowController(window: window)
    summarySetupWC = controller
    controller.showWindow(nil)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
