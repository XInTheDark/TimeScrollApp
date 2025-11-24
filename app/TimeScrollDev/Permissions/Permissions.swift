import Foundation
import CoreGraphics
import AppKit

enum Permissions {
    enum PrivacyPane {
        case screenRecording

        var url: URL? {
            switch self {
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }
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

