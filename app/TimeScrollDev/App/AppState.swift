import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var isCapturing: Bool = false
    @Published var lastSnapshotURL: URL?

    let snapshotStore = SnapshotStore.shared
    lazy var captureManager: CaptureManager = {
        let manager = CaptureManager { [weak self] url in
            Task { @MainActor in
                if !VaultManager.shared.isVaultEnabled || VaultManager.shared.isUnlocked {
                    self?.lastSnapshotURL = url
                }
            }
        }
        return manager
    }()

    func enforceRetention() {
        let days = SettingsStore.shared.retentionDays
        Task.detached {
            try? DB.shared.purgeOlderThan(days: days)
        }
    }

    func startCaptureIfNeeded() async {
        if isCapturing { return }
        Permissions.requestScreenRecording()
        try? await captureManager.start()
        isCapturing = true
    }

    func stopCaptureIfNeeded() async {
        if !isCapturing { return }
        await captureManager.stop()
        isCapturing = false
    }

    func restartCaptureIfRunning() async {
        if !isCapturing { return }
        await stopCaptureIfNeeded()
        await startCaptureIfNeeded()
    }
}
