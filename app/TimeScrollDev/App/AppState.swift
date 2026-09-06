import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isCapturing: Bool = false
    @Published private(set) var isCaptureStarting: Bool = false
    @Published private(set) var screenCaptureStatus: CaptureSourceStatus = .inactive
    @Published private(set) var microphoneCaptureStatus: CaptureSourceStatus = .inactive
    @Published private(set) var systemAudioCaptureStatus: CaptureSourceStatus = .inactive
    @Published var lastSnapshotURL: URL?
    // Always increments for every snapshot row inserted so SwiftUI can react
    @Published var lastSnapshotTick: Int = 0

    let snapshotStore = SnapshotStore.shared

    lazy var captureManager: CaptureManager = {
        let manager = CaptureManager { [weak self] url in
            Task { @MainActor in
                if !VaultManager.shared.isVaultEnabled || VaultManager.shared.isUnlocked {
                    self?.lastSnapshotURL = url
                    self?.lastSnapshotTick &+= 1
                }
            }
        }
        return manager
    }()

    let audioCaptureController = AudioCaptureController()
    private var audioPausedForVault = false
    private var captureLifecycleGeneration = 0
    private var captureTransitionInProgress = false
    private var captureStopInProgress = false

    func enforceRetention() {
        let days = SettingsStore.shared.retentionDays
        Task.detached {
            try? DB.shared.purgeOlderThan(days: days)
            DB.shared.pruneOldOCRBoxesIfConfigured()
            await MainActor.run {
                StorageMaintenanceManager.shared.runIfNeeded(forceMaintenance: true, afterLargeDelete: true)
            }
        }
    }

    func startCaptureIfNeeded() async {
        if isCapturing || isCaptureStarting || captureTransitionInProgress { return }
        captureLifecycleGeneration &+= 1
        let generation = captureLifecycleGeneration
        captureTransitionInProgress = true
        isCaptureStarting = true
        defer {
            if captureLifecycleGeneration == generation {
                captureTransitionInProgress = false
                isCaptureStarting = false
            }
        }

        let selection = CaptureModeSelection(defaults: .standard)
        guard selection.hasAnyCaptureEnabled else { return }

        let screenPermissionGranted: Bool
        if !selection.requiresScreenRecordingPermission || Permissions.isScreenRecordingGranted() {
            screenPermissionGranted = true
        } else {
            screenPermissionGranted = await Permissions.requestScreenRecording()
        }
        guard captureLifecycleGeneration == generation else { return }
        let microphonePermissionGranted: Bool
        if !selection.requiresMicrophonePermission || Permissions.isMicrophoneGranted() {
            microphonePermissionGranted = true
        } else {
            microphonePermissionGranted = await Permissions.requestMicrophone()
        }
        guard captureLifecycleGeneration == generation else { return }

        var startedScreen = false
        var startedAudio = false

        if selection.capturesScreen {
            if screenPermissionGranted {
                screenCaptureStatus = .starting
                do {
                    try await captureManager.start()
                    guard captureLifecycleGeneration == generation else {
                        await captureManager.stop()
                        return
                    }
                    startedScreen = true
                    screenCaptureStatus = .running
                } catch {
                    fputs("[Capture] Failed to start screen capture: \(error.localizedDescription)\n", stderr)
                    screenCaptureStatus = .failed(error.localizedDescription)
                }
            } else {
                screenCaptureStatus = .failed("Screen Recording permission is required.")
            }
        } else {
            screenCaptureStatus = .inactive
        }

        if selection.capturesAudio {
            if VaultManager.shared.isVaultEnabled && !VaultManager.shared.isUnlocked {
                audioPausedForVault = true
                microphoneCaptureStatus = selection.capturesMicrophone ? .pausedForVault : .inactive
                systemAudioCaptureStatus = selection.capturesSystemAudio ? .pausedForVault : .inactive
            } else {
                audioPausedForVault = false
                await AudioSegmentProcessor.shared.resumePendingWork()
                microphoneCaptureStatus = selection.capturesMicrophone ? .starting : .inactive
                systemAudioCaptureStatus = selection.capturesSystemAudio ? .starting : .inactive
                let result = await audioCaptureController.start(
                    captureMicrophone: selection.capturesMicrophone && microphonePermissionGranted,
                    captureSystemAudio: selection.capturesSystemAudio && screenPermissionGranted
                )
                guard captureLifecycleGeneration == generation else {
                    await audioCaptureController.stop(drainProcessing: false)
                    return
                }
                startedAudio = result.startedAny
                microphoneCaptureStatus = sourceStatus(requested: selection.capturesMicrophone,
                                                       permissionGranted: microphonePermissionGranted,
                                                       started: result.microphoneStarted,
                                                       error: result.microphoneError,
                                                       permissionName: "Microphone")
                systemAudioCaptureStatus = sourceStatus(requested: selection.capturesSystemAudio,
                                                        permissionGranted: screenPermissionGranted,
                                                        started: result.systemAudioStarted,
                                                        error: result.systemAudioError,
                                                        permissionName: "Screen Recording")
            }
        } else {
            microphoneCaptureStatus = .inactive
            systemAudioCaptureStatus = .inactive
        }

        isCapturing = startedScreen || startedAudio || audioPausedForVault
        if isCapturing {
            UsageTracker.shared.captureStarted()
        }
    }

    func stopCaptureIfNeeded() async {
        guard !captureStopInProgress else { return }
        captureStopInProgress = true
        defer { captureStopInProgress = false }
        captureLifecycleGeneration &+= 1
        captureTransitionInProgress = true
        isCaptureStarting = false
        await captureManager.stop()
        await audioCaptureController.stop(drainProcessing: false)
        isCapturing = false
        audioPausedForVault = false
        screenCaptureStatus = .inactive
        microphoneCaptureStatus = .inactive
        systemAudioCaptureStatus = .inactive
        UsageTracker.shared.captureStopped()
        captureTransitionInProgress = false
    }

    func restartCaptureIfRunning() async {
        if !isCapturing { return }
        await stopCaptureIfNeeded()
        await startCaptureIfNeeded()
    }

    func retryNewlyAuthorizedSourcesIfNeeded() async {
        guard isCapturing else { return }
        let selection = CaptureModeSelection(defaults: .standard)
        let requestedModel = UserDefaults.standard.string(forKey: "settings.whisperModelID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = requestedModel?.isEmpty == false ? requestedModel! : SettingsStore.defaultWhisperModelID
        let audioModelReady = WhisperModelStore.isModelAvailable(modelID)
        let microphoneBecameAvailable = selection.capturesMicrophone
            && !microphoneCaptureStatus.isRunning
            && Permissions.isMicrophoneGranted()
            && audioModelReady
        let systemAudioBecameAvailable = selection.capturesSystemAudio
            && !systemAudioCaptureStatus.isRunning
            && Permissions.isScreenRecordingGranted()
            && audioModelReady
        let screenBecameAvailable = selection.capturesScreen
            && !screenCaptureStatus.isRunning
            && Permissions.isScreenRecordingGranted()
        if microphoneBecameAvailable || systemAudioBecameAvailable || screenBecameAvailable {
            await restartCaptureIfRunning()
        }
    }

    func pauseAudioForVaultLock() async {
        let selection = CaptureModeSelection(defaults: .standard)
        let shouldResumeAudio = isCapturing && selection.capturesAudio
        await audioCaptureController.stop(drainProcessing: false)
        await AudioSegmentProcessor.shared.pauseForVaultLock()
        audioPausedForVault = shouldResumeAudio
        microphoneCaptureStatus = shouldResumeAudio && selection.capturesMicrophone ? .pausedForVault : .inactive
        systemAudioCaptureStatus = shouldResumeAudio && selection.capturesSystemAudio ? .pausedForVault : .inactive
    }

    func resumeAudioAfterVaultUnlockIfNeeded() async {
        guard isCapturing, audioPausedForVault else {
            audioPausedForVault = false
            await AudioSegmentProcessor.shared.resumePendingWork()
            return
        }
        audioPausedForVault = false
        let selection = CaptureModeSelection(defaults: .standard)
        let result = await audioCaptureController.start()
        microphoneCaptureStatus = sourceStatus(requested: selection.capturesMicrophone,
                                               permissionGranted: Permissions.isMicrophoneGranted(),
                                               started: result.microphoneStarted,
                                               error: result.microphoneError,
                                               permissionName: "Microphone")
        systemAudioCaptureStatus = sourceStatus(requested: selection.capturesSystemAudio,
                                                permissionGranted: Permissions.isScreenRecordingGranted(),
                                                started: result.systemAudioStarted,
                                                error: result.systemAudioError,
                                                permissionName: "Screen Recording")
    }

    func shutdown() async {
        captureLifecycleGeneration &+= 1
        captureTransitionInProgress = true
        isCaptureStarting = false
        await captureManager.stop()
        await audioCaptureController.stop(drainProcessing: false)
        let drained = await AudioSegmentProcessor.shared.drain(timeoutNanoseconds: 10_000_000_000)
        if !drained {
            fputs("[Audio] Shutdown timed out while transcribing; pending work will resume on next launch.\n", stderr)
        }
        isCapturing = false
        captureTransitionInProgress = false
    }

    private func sourceStatus(requested: Bool,
                              permissionGranted: Bool,
                              started: Bool,
                              error: String?,
                              permissionName: String) -> CaptureSourceStatus {
        guard requested else { return .inactive }
        guard permissionGranted else { return .failed("\(permissionName) permission is required.") }
        if started { return .running }
        return .failed(error ?? "The capture source could not start.")
    }
}
