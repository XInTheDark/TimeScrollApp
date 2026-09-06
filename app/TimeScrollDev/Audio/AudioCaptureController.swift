import Foundation

@MainActor
final class AudioCaptureController {
    private var microphoneRecorder: MicrophoneAudioRecorder?
    private var systemRecorder: SystemAudioRecorder?
    private let segmentSubmitter = AudioSegmentSubmitter()
    private var lifecycleGeneration = 0
    private var isStarting = false

    private(set) var isRunning = false

    @discardableResult
    func start(captureMicrophone: Bool? = nil,
               captureSystemAudio: Bool? = nil) async -> AudioCaptureStartResult {
        if isRunning {
            return AudioCaptureStartResult(microphoneStarted: microphoneRecorder != nil,
                                           systemAudioStarted: systemRecorder != nil)
        }
        guard !isStarting else {
            return AudioCaptureStartResult(microphoneError: "Audio capture is already starting.",
                                           systemAudioError: "Audio capture is already starting.")
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isStarting = true
        defer {
            if lifecycleGeneration == generation {
                isStarting = false
            }
        }

        let selection = CaptureModeSelection(defaults: .standard)
        let shouldCaptureMicrophone = captureMicrophone ?? selection.capturesMicrophone
        let shouldCaptureSystemAudio = captureSystemAudio ?? selection.capturesSystemAudio
        guard shouldCaptureMicrophone || shouldCaptureSystemAudio else { return AudioCaptureStartResult() }

        let defaults = UserDefaults.standard
        let modelID = Self.selectedWhisperModelID(defaults: defaults)
        guard WhisperModelStore.isModelAvailable(modelID) else {
            let message = "Download the selected Whisper model and tokenizer before starting audio capture."
            return AudioCaptureStartResult(microphoneError: shouldCaptureMicrophone ? message : nil,
                                           systemAudioError: shouldCaptureSystemAudio ? message : nil)
        }

        let configuredSegmentDuration = defaults.integer(forKey: "settings.audioSegmentDurationSeconds")
        let effectiveSegmentDuration = configuredSegmentDuration > 0
            ? configuredSegmentDuration
            : SettingsStore.defaultAudioSegmentDurationSeconds
        let segmentDuration = TimeInterval(max(5, effectiveSegmentDuration))
        let submitter = segmentSubmitter
        let onSegmentFinished: @Sendable (RecordedAudioSegment) -> Void = { segment in
            submitter.submit(segment, modelID: modelID)
        }
        var result = AudioCaptureStartResult()

        if shouldCaptureMicrophone {
            do {
                let recorder = MicrophoneAudioRecorder(
                    selectedDeviceID: defaults.string(forKey: "settings.selectedAudioInputDeviceID"),
                    segmentDuration: segmentDuration,
                    onSegmentFinished: onSegmentFinished
                )
                try recorder.start()
                microphoneRecorder = recorder
                result.microphoneStarted = true
            } catch {
                fputs("[Audio] Failed to start microphone capture: \(error.localizedDescription)\n", stderr)
                result.microphoneError = error.localizedDescription
            }
        }

        if shouldCaptureSystemAudio {
            do {
                let recorder = SystemAudioRecorder(
                    segmentDuration: segmentDuration,
                    onSegmentFinished: onSegmentFinished
                )
                try await recorder.start()
                guard lifecycleGeneration == generation else {
                    await recorder.stop()
                    return AudioCaptureStartResult()
                }
                systemRecorder = recorder
                result.systemAudioStarted = true
            } catch {
                fputs("[Audio] Failed to start system audio capture: \(error.localizedDescription)\n", stderr)
                result.systemAudioError = error.localizedDescription
            }
        }

        guard lifecycleGeneration == generation else { return AudioCaptureStartResult() }
        isRunning = result.startedAny
        return result
    }

    private static func selectedWhisperModelID(defaults: UserDefaults) -> String {
        let requestedModel = defaults.string(forKey: "settings.whisperModelID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return requestedModel?.isEmpty == false ? requestedModel! : SettingsStore.defaultWhisperModelID
    }

    func stop(drainProcessing: Bool = true) async {
        lifecycleGeneration &+= 1
        isStarting = false
        let microphoneRecorder = microphoneRecorder
        let systemRecorder = systemRecorder
        self.microphoneRecorder = nil
        self.systemRecorder = nil
        await microphoneRecorder?.stop()
        await systemRecorder?.stop()
        await segmentSubmitter.drainSubmissions()
        if drainProcessing {
            await AudioSegmentProcessor.shared.drain()
        }
        isRunning = false
    }
}
