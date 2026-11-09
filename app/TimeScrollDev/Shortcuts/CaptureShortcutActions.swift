import Foundation

/// What the Start, Stop and Get Capture State shortcuts do, independent of App Intents.
@MainActor
struct CaptureShortcutActions {
    let controller: CaptureControlling
    let hasAnyCaptureEnabled: () -> Bool

    static func live() -> CaptureShortcutActions {
        CaptureShortcutActions(controller: AppState.shared) {
            CaptureModeSelection(defaults: .standard).hasAnyCaptureEnabled
        }
    }

    /// Starts capture, waiting for a start already in flight, and returns once capture is on.
    func start() async throws {
        if controller.isCapturing { return }
        if !controller.isCaptureStarting {
            guard hasAnyCaptureEnabled() else { throw CaptureShortcutError.nothingSelectedToRecord }
            await controller.startCaptureIfNeeded()
        }
        if controller.isCaptureStarting {
            await controller.waitUntilCaptureStartSettles()
        }
        guard controller.isCapturing else {
            throw CaptureShortcutError.didNotStart(reason: controller.captureFailureMessage)
        }
    }

    /// Stops capture, cancelling a start in flight.
    func stop() async {
        await controller.stopCaptureIfNeeded()
    }

    var isCapturing: Bool {
        controller.isCapturing
    }
}
