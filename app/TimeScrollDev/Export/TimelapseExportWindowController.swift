import AppKit
import SwiftUI

@MainActor
final class TimelapseExportWindowController: NSWindowController, NSWindowDelegate {
  static let shared = TimelapseExportWindowController()
  private let model = TimelapseExportModel()

  func present() {
    NSApp.setActivationPolicy(.regular)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Opens with `range` filled in, unless an export is running.
  func present(range: TimelineRange) {
    if !model.isExporting {
      model.options.start = Date(timeIntervalSince1970: TimeInterval(range.fromMs) / 1000)
      model.options.end = Date(timeIntervalSince1970: TimeInterval(range.toMs) / 1000)
    }
    present()
  }

  init() {
    let hosting = NSHostingController(rootView: TimelapseExportView(model: model))
    let window = NSWindow(contentViewController: hosting)
    let size = hosting.sizeThatFits(in: CGSize(width: 480, height: CGFloat.greatestFiniteMagnitude))
    window.setContentSize(NSSize(width: 480, height: ceil(size.height)))
    window.title = "Export Timelapse"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard model.isExporting else { return true }
    let alert = NSAlert()
    alert.messageText = "Cancel this export?"
    alert.informativeText = "The unfinished video will be discarded."
    alert.addButton(withTitle: "Keep Exporting")
    alert.addButton(withTitle: "Cancel Export")
    if alert.runModal() == .alertSecondButtonReturn { model.cancel() }
    return false
  }
}
