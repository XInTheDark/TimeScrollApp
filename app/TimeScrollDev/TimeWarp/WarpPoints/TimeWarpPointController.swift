import AppKit
import Foundation

/// Adds Warp points from the shortcut and the menu bar, and keeps the shortcut registered only
/// while Time Warp and the shortcut setting are on.
@MainActor
final class TimeWarpPointController {
  static let shared = TimeWarpPointController()

  private lazy var hotKey = TimeWarpHotKey { [weak self] in self?.addWarpPoint() }
  private var panel: TimeWarpPointPanel?
  private var settingsToken: NSObjectProtocol?

  func start() {
    guard settingsToken == nil else { return }
    settingsToken = NotificationCenter.default.addObserver(forName: TimeWarpSettings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateHotKey() }
    }
    updateHotKey()
  }

  /// Asks for a note, then records the point at the time this was called.
  func addWarpPoint() {
    let recorder = TimeWarpRecorder.shared
    guard recorder.isRecording else {
      NSSound.beep()
      return
    }
    let atMs = TimeWarpRecorder.nowMs()
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let panel = panel ?? TimeWarpPointPanel()
    self.panel = panel
    panel.present { note in recorder.addWarpPoint(note: note, atMs: atMs, appBundleId: front) }
  }

  private func updateHotKey() {
    if TimeWarpSettings.isEnabled() && TimeWarpSettings.warpPointShortcutEnabled() {
      hotKey.register()
    } else {
      hotKey.unregister()
    }
  }
}
