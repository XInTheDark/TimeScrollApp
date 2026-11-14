import AppKit
import Combine
import SwiftUI

/// The Time Warp window. One at a time; presenting again shows the new range or moment.
@MainActor
final class TimeWarpWindowController: NSWindowController, NSWindowDelegate {
  static let shared = TimeWarpWindowController()
  private let model = TimeWarpSheetModel(range: TimelineRange(fromMs: 0, toMs: 1000)!)
  private var vaultObservation: AnyCancellable?

  func present(range: TimelineRange) {
    present(target: .range(range))
  }

  /// What was in use up to this moment, looking back as far as the user last chose.
  func present(momentMs: Int64) {
    present(target: .moment(momentMs))
  }

  func present(target: TimeWarpTarget) {
    guard TimeWarpSheetModel.vaultIsOpen() else { NSSound.beep(); return }
    model.show(target: target)
    NSApp.setActivationPolicy(.regular)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  init() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
    window.title = "Time Warp"
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 420, height: 360)
    super.init(window: window)
    window.contentViewController = NSHostingController(rootView: TimeWarpView(model: model) { [weak window] in
      window?.performClose(nil)
    })
    window.setContentSize(NSSize(width: 540, height: 560))
    window.delegate = self
    window.setFrameAutosaveName("TimeWarpWindow")
    window.center()
    // Locking the vault hides what was loaded from it.
    let vault = VaultManager.shared
    vaultObservation = vault.$isUnlocked.combineLatest(vault.$isVaultEnabled)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] unlocked, enabled in
        guard let self, enabled && !unlocked else { return }
        self.model.lock()
        self.window?.close()
      }
  }

  required init?(coder: NSCoder) { nil }
}
