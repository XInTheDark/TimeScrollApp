import SwiftUI
import AppKit

/// Weak handle to the window hosting a SwiftUI view; held in `@State` without retaining the window.
final class HostingWindowReference {
    weak var window: NSWindow?
}

/// Records the NSWindow that hosts a SwiftUI view, e.g. to scope app-wide event monitors to it.
struct HostingWindowReader: NSViewRepresentable {
    let reference: HostingWindowReference

    func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingView()
        view.reference = reference
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowTrackingView)?.reference = reference
    }

    private final class WindowTrackingView: NSView {
        var reference: HostingWindowReference? {
            didSet { reference?.window = window }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}
