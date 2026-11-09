import Foundation

enum CaptureShortcutError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case nothingSelectedToRecord
    case didNotStart(reason: String?)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingSelectedToRecord:
            return "Nothing is set to record. Turn on screen or audio recording in TimeScroll Settings."
        case .didNotStart(let reason?):
            return "Capture didn’t start. \(reason)"
        case .didNotStart(nil):
            return "Capture didn’t start."
        }
    }
}
