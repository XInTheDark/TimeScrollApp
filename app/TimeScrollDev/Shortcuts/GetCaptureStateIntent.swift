import AppIntents

struct GetCaptureStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Is TimeScroll Capturing"
    static let description = IntentDescription("Returns whether TimeScroll is recording.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let capturing = CaptureShortcutActions.live().isCapturing
        return .result(value: capturing,
                       dialog: capturing ? "TimeScroll is capturing." : "TimeScroll isn’t capturing.")
    }
}
