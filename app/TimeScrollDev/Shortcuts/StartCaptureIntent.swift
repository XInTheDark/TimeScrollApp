import AppIntents

struct StartCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Capture"
    static let description = IntentDescription("Starts recording in TimeScroll.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await CaptureShortcutActions.live().start()
        return .result()
    }
}
