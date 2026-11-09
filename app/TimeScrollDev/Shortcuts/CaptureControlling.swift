import Foundation

/// The capture lifecycle that Shortcuts actions drive.
@MainActor
protocol CaptureControlling: AnyObject {
    var isCapturing: Bool { get }
    var isCaptureStarting: Bool { get }
    /// The first source error left by the last start attempt, if any.
    var captureFailureMessage: String? { get }
    func startCaptureIfNeeded() async
    func stopCaptureIfNeeded() async
    /// Returns once no start is in flight.
    func waitUntilCaptureStartSettles() async
}

extension AppState: CaptureControlling {
    var captureFailureMessage: String? {
        screenCaptureStatus.errorMessage
            ?? microphoneCaptureStatus.errorMessage
            ?? systemAudioCaptureStatus.errorMessage
    }

    func waitUntilCaptureStartSettles() async {
        for await starting in $isCaptureStarting.values where !starting {
            return
        }
    }
}
