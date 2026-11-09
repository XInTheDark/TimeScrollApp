import AppIntents

struct StopCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Capture"
    static let description = IntentDescription("Stops recording in TimeScroll.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await CaptureShortcutActions.live().stop()
        return .result()
    }
}
