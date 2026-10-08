import AppKit
import ApplicationServices

/// Reads the focused window title of an app through Accessibility, with a short IPC timeout.
/// Returns nil when Accessibility is not granted or the app does not answer quickly.
enum FrontWindowTitleReader {
    private static let timeoutSeconds: Float = 0.1

    static func title(forProcess pid: pid_t) -> String? {
        guard pid > 0, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeoutSeconds)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
