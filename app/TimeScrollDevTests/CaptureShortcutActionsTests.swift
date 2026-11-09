import Foundation
import Testing
@testable import TimeScroll

@MainActor
private final class FakeCaptureController: CaptureControlling {
  var isCapturing = false
  var isCaptureStarting = false
  var captureFailureMessage: String?
  var startResult = true
  var startCalls = 0
  var stopCalls = 0
  var waitCalls = 0
  /// What an in-flight start resolves to when the shortcut waits on it.
  var inFlightStartResult = true

  func startCaptureIfNeeded() async {
    startCalls += 1
    if isCapturing || isCaptureStarting { return }
    isCapturing = startResult
  }

  func stopCaptureIfNeeded() async {
    stopCalls += 1
    isCaptureStarting = false
    isCapturing = false
  }

  func waitUntilCaptureStartSettles() async {
    waitCalls += 1
    guard isCaptureStarting else { return }
    isCaptureStarting = false
    isCapturing = inFlightStartResult
  }
}

@MainActor
struct CaptureShortcutActionsTests {
  private func actions(_ controller: FakeCaptureController, enabled: Bool = true) -> CaptureShortcutActions {
    CaptureShortcutActions(controller: controller) { enabled }
  }

  @Test func startTurnsCaptureOn() async throws {
    let controller = FakeCaptureController()
    try await actions(controller).start()
    #expect(controller.isCapturing)
    #expect(controller.startCalls == 1)
    #expect(controller.waitCalls == 0)
  }

  @Test func startWhenAlreadyCapturingDoesNothing() async throws {
    let controller = FakeCaptureController()
    controller.isCapturing = true
    try await actions(controller).start()
    #expect(controller.startCalls == 0)
    #expect(controller.isCapturing)
  }

  @Test func startAlreadyCapturingSucceedsEvenWithNoSourcesEnabled() async throws {
    let controller = FakeCaptureController()
    controller.isCapturing = true
    try await actions(controller, enabled: false).start()
    #expect(controller.isCapturing)
  }

  @Test func startWithNothingSelectedThrowsWithoutStarting() async {
    let controller = FakeCaptureController()
    await #expect(throws: CaptureShortcutError.nothingSelectedToRecord) {
      try await actions(controller, enabled: false).start()
    }
    #expect(controller.startCalls == 0)
    #expect(!controller.isCapturing)
  }

  @Test func startWaitsForStartInFlight() async throws {
    let controller = FakeCaptureController()
    controller.isCaptureStarting = true
    try await actions(controller).start()
    #expect(controller.startCalls == 0)
    #expect(controller.waitCalls == 1)
    #expect(controller.isCapturing)
  }

  @Test func startInFlightThatFailsReportsReason() async {
    let controller = FakeCaptureController()
    controller.isCaptureStarting = true
    controller.inFlightStartResult = false
    controller.captureFailureMessage = "Screen Recording permission is required."
    await #expect(throws: CaptureShortcutError.didNotStart(reason: "Screen Recording permission is required.")) {
      try await actions(controller).start()
    }
  }

  @Test func startFailureWithoutReason() async {
    let controller = FakeCaptureController()
    controller.startResult = false
    await #expect(throws: CaptureShortcutError.didNotStart(reason: nil)) {
      try await actions(controller).start()
    }
    #expect(controller.startCalls == 1)
  }

  @Test func stopTurnsCaptureOff() async {
    let controller = FakeCaptureController()
    controller.isCapturing = true
    await actions(controller).stop()
    #expect(controller.stopCalls == 1)
    #expect(!controller.isCapturing)
  }

  @Test func stopWhenIdleIsHarmless() async {
    let controller = FakeCaptureController()
    await actions(controller).stop()
    #expect(controller.stopCalls == 1)
    #expect(!controller.isCapturing)
  }

  @Test func stopCancelsStartInFlight() async {
    let controller = FakeCaptureController()
    controller.isCaptureStarting = true
    await actions(controller).stop()
    #expect(!controller.isCaptureStarting)
    #expect(!controller.isCapturing)
  }

  @Test func stateReflectsController() {
    let controller = FakeCaptureController()
    let actions = actions(controller)
    #expect(!actions.isCapturing)
    controller.isCapturing = true
    #expect(actions.isCapturing)
  }

  @Test func errorMessagesAreUserReadable() {
    #expect(String(localized: CaptureShortcutError.didNotStart(reason: "Mic busy.").localizedStringResource)
            == "Capture didn’t start. Mic busy.")
    #expect(String(localized: CaptureShortcutError.didNotStart(reason: nil).localizedStringResource)
            == "Capture didn’t start.")
  }
}
