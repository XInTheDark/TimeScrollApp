import Foundation

enum CaptureKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case screen
    case audio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screen: return "Screen"
        case .audio: return "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .screen: return "display"
        case .audio: return "waveform"
        }
    }
}

enum AudioSourceKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case microphone
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .system: return "System Audio"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .microphone: return "Mic"
        case .system: return "System"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .system: return "speaker.wave.2"
        }
    }

    var fallbackAppName: String { displayName }
}

struct AudioTranscriptSegment: Codable, Hashable, Identifiable {
    let id: Int
    let relativeStartMs: Int64
    let relativeEndMs: Int64
    let text: String

    var durationMs: Int64 {
        max(0, relativeEndMs - relativeStartMs)
    }
}

enum AudioTranscriptionStatus: String, Codable, Hashable {
    case pending
    case completed
    case failed
}
