import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

enum Permissions {
    enum PrivacyPane {
        case screenRecording
        case accessibility

        var url: URL? {
            switch self {
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    static func isAccessibilityGranted() -> Bool {
        // Fast check (no prompt)
        return AXIsProcessTrusted()
    }

    /// Triggers the system prompt to grant Accessibility access; also opens Settings.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let opts: NSDictionary = [key: true] // prompt asynchronously
        _ = AXIsProcessTrustedWithOptions(opts)
        // Open pane to help user complete trust
        _ = open(.accessibility)
    }

    static func isScreenRecordingGranted() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt (if possible) to request Screen Recording access.
    /// Falls back to opening the System Settings privacy pane.
    static func requestScreenRecording() {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            _ = CGRequestScreenCaptureAccess()
            // Also direct users to the exact pane in case the prompt doesn't appear
            open(.screenRecording)
        }
    }

    /// Opens the specific System Settings privacy pane for the given case.
    @discardableResult
    static func open(_ pane: PrivacyPane) -> Bool {
        guard let url = pane.url else { return false }
        return NSWorkspace.shared.open(url)
    }
}

