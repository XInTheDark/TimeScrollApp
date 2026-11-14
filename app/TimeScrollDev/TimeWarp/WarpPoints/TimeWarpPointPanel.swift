import AppKit
import SwiftUI

/// A small floating field for a Warp point's note. It takes typing without bringing TimeScroll to
/// the front, so the app the user was in stays the one recorded.
@MainActor
final class TimeWarpPointPanel: NSPanel {
  private let model = TimeWarpPointNoteModel()

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
               styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
               backing: .buffered, defer: true)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    contentView = NSHostingView(rootView: TimeWarpPointNoteView(model: model))
  }

  override var canBecomeKey: Bool { true }

  /// Shows the field; `onSave` gets the note, possibly empty, when the user presses Return.
  func present(onSave: @escaping (String) -> Void) {
    model.text = ""
    model.onSave = { [weak self] note in
      onSave(note)
      self?.orderOut(nil)
    }
    model.onCancel = { [weak self] in self?.orderOut(nil) }
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.maxY - frame.height * 0.28))
    }
    makeKeyAndOrderFront(nil)
    model.focusRequest &+= 1
  }

  override func cancelOperation(_ sender: Any?) {
    orderOut(nil)
  }

  override func resignKey() {
    super.resignKey()
    orderOut(nil)
  }
}
