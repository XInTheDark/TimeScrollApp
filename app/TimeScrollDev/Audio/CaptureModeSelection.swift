import Foundation

struct CaptureModeSelection: Equatable, Sendable {
    let audioFeatureEnabled: Bool
    let captureScreenEnabled: Bool
    let captureAudioEnabled: Bool
    let captureMicrophoneEnabled: Bool
    let captureSystemAudioEnabled: Bool

    init(audioFeatureEnabled: Bool,
         captureScreenEnabled: Bool,
         captureAudioEnabled: Bool,
         captureMicrophoneEnabled: Bool,
         captureSystemAudioEnabled: Bool) {
        self.audioFeatureEnabled = audioFeatureEnabled
        self.captureScreenEnabled = captureScreenEnabled
        self.captureAudioEnabled = captureAudioEnabled
        self.captureMicrophoneEnabled = captureMicrophoneEnabled
        self.captureSystemAudioEnabled = captureSystemAudioEnabled
    }

    @MainActor
    init(settings: SettingsStore) {
        self.init(audioFeatureEnabled: settings.audioFeatureEnabled,
                  captureScreenEnabled: settings.captureScreenEnabled,
                  captureAudioEnabled: settings.captureAudioEnabled,
                  captureMicrophoneEnabled: settings.captureMicrophoneEnabled,
                  captureSystemAudioEnabled: settings.captureSystemAudioEnabled)
    }

    init(defaults: UserDefaults = .standard) {
        let audioFeatureEnabled: Bool
        if defaults.object(forKey: "settings.audioFeatureEnabled") != nil {
            audioFeatureEnabled = defaults.bool(forKey: "settings.audioFeatureEnabled")
        } else {
            audioFeatureEnabled = SettingsStore.defaultAudioFeatureEnabled
        }

        let captureScreenEnabled: Bool
        if defaults.object(forKey: "settings.captureScreenEnabled") != nil {
            captureScreenEnabled = defaults.bool(forKey: "settings.captureScreenEnabled")
        } else {
            captureScreenEnabled = SettingsStore.defaultCaptureScreenEnabled
        }

        let captureAudioEnabled: Bool
        if defaults.object(forKey: "settings.captureAudioEnabled") != nil {
            captureAudioEnabled = defaults.bool(forKey: "settings.captureAudioEnabled")
        } else {
            captureAudioEnabled = SettingsStore.defaultCaptureAudioEnabled
        }

        let captureMicrophoneEnabled: Bool
        if defaults.object(forKey: "settings.captureMicrophoneEnabled") != nil {
            captureMicrophoneEnabled = defaults.bool(forKey: "settings.captureMicrophoneEnabled")
        } else {
            captureMicrophoneEnabled = SettingsStore.defaultCaptureMicrophoneEnabled
        }

        let captureSystemAudioEnabled: Bool
        if defaults.object(forKey: "settings.captureSystemAudioEnabled") != nil {
            captureSystemAudioEnabled = defaults.bool(forKey: "settings.captureSystemAudioEnabled")
        } else {
            captureSystemAudioEnabled = SettingsStore.defaultCaptureSystemAudioEnabled
        }

        self.init(audioFeatureEnabled: audioFeatureEnabled,
                  captureScreenEnabled: captureScreenEnabled,
                  captureAudioEnabled: captureAudioEnabled,
                  captureMicrophoneEnabled: captureMicrophoneEnabled,
                  captureSystemAudioEnabled: captureSystemAudioEnabled)
    }

    /// Preserve TimeScroll's current UX when the optional audio feature is disabled:
    /// screen capture stays on exactly as before.
    var capturesScreen: Bool {
        !audioFeatureEnabled || captureScreenEnabled
    }

    var capturesMicrophone: Bool {
        audioFeatureEnabled && captureAudioEnabled && captureMicrophoneEnabled
    }

    var capturesSystemAudio: Bool {
        audioFeatureEnabled && captureAudioEnabled && captureSystemAudioEnabled
    }

    var capturesAudio: Bool {
        capturesMicrophone || capturesSystemAudio
    }

    var requiresScreenRecordingPermission: Bool {
        capturesScreen || capturesSystemAudio
    }

    var requiresMicrophonePermission: Bool {
        capturesMicrophone
    }

    var hasAnyCaptureEnabled: Bool {
        capturesScreen || capturesAudio
    }
}
