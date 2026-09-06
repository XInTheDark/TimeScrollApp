import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    enum PrivacyPane {
        case screenRecording
        case accessibility
        case microphone

        var url: URL? {
            switch self {
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
        }
    }

    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt to grant Accessibility access; also opens Settings.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let opts: NSDictionary = [key: true]
        _ = AXIsProcessTrustedWithOptions(opts)
        _ = open(.accessibility)
    }

    static func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt (if possible) to request Screen Recording access.
    /// Falls back to opening the System Settings privacy pane.
    @MainActor
    static func requestScreenRecording() async -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        guard !granted else { return true }
        let requested = CGRequestScreenCaptureAccess()
        if !requested {
            open(.screenRecording)
        }
        return requested || CGPreflightScreenCaptureAccess()
    }

    static func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    open(.microphone)
                }
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            open(.microphone)
            return false
        @unknown default:
            open(.microphone)
            return false
        }
    }

    static func hasRequiredCapturePermissions(for selection: CaptureModeSelection,
                                              textProcessingMode: SettingsStore.TextProcessingMode) -> Bool {
        guard selection.hasAnyCaptureEnabled else { return true }
        if selection.requiresScreenRecordingPermission && !isScreenRecordingGranted() {
            return false
        }
        if selection.requiresMicrophonePermission && !isMicrophoneGranted() {
            return false
        }
        if textProcessingMode == .accessibility && !isAccessibilityGranted() {
            return false
        }
        return true
    }

    /// Opens the specific System Settings privacy pane for the given case.
    @discardableResult
    static func open(_ pane: PrivacyPane) -> Bool {
        guard let url = pane.url else { return false }
        return NSWorkspace.shared.open(url)
    }
}
