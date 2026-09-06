import Foundation
import LocalAuthentication
import AppKit


@MainActor
final class VaultManager: ObservableObject {
    static let shared = VaultManager()

    @Published private(set) var isVaultEnabled: Bool = false
    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var queuedCount: Int = 0

    private var inactivityTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var lockInProgress = false

    private init() {
        loadPrefs()
        // Observe defaults changes to reflect queued count and unlocked state in UI
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let d = UserDefaults.standard
            let q = d.integer(forKey: "vault.queuedCount")
            let u = d.bool(forKey: "vault.isUnlocked")
            Task { @MainActor in
                if q != self.queuedCount { self.queuedCount = max(0, q) }
                if u != self.isUnlocked { self.isUnlocked = u }
            }
        }
    }

    func loadPrefs() {
        let d = UserDefaults.standard
        if d.object(forKey: "settings.vaultEnabled") != nil {
            isVaultEnabled = d.bool(forKey: "settings.vaultEnabled")
        } else {
            isVaultEnabled = false
        }
        // Always start locked on fresh launch for security; do not persist unlocked across restarts
        isUnlocked = false
        persistUnlocked(false)
        queuedCount = d.integer(forKey: "vault.queuedCount")
    }

    func setVaultEnabled(_ enabled: Bool) async {
        let resumeCapture = enabled != isVaultEnabled && AppState.shared.isCapturing
        if resumeCapture { await AppState.shared.stopCaptureIfNeeded() }
        if enabled {
            try? KeyStore.shared.ensureKEK()
            try? KeyStore.shared.createAndWrapDbKeyIfMissing()
        }
        if enabled != isVaultEnabled {
            await AppState.shared.pauseAudioForVaultLock()
        }
        isVaultEnabled = enabled
        let d = UserDefaults.standard
        d.set(enabled, forKey: "settings.vaultEnabled")
        StoragePaths.setShared(enabled, forKey: "settings.vaultEnabled")
        d.synchronize()
        if enabled {
            // Close any existing plaintext DB connection so migration can safely replace the file
            DB.shared.close()
            // File migration resumes after authenticated unlock.
        } else {
            // When disabling, perform reverse DB migration so plaintext DB continues to work
            if let key = try? KeyStore.shared.unwrapDbKey() {
                // Ensure DB is closed before replacing the file
                SQLCipherBridge.shared.close()
                SQLCipherBridge.shared.migrateEncryptedToPlaintextIfNeeded(withKey: key)
            }
            performLock()
            await AppState.shared.resumeAudioAfterVaultUnlockIfNeeded()
        }
        if resumeCapture { await AppState.shared.startCaptureIfNeeded() }
    }

    func unlock(presentingWindow: NSWindow? = nil) async {
        guard isVaultEnabled else { return }
        do {
            let key = try await KeyStore.shared.authenticateAndUnwrapDbKey(presentingWindow: presentingWindow)

            isUnlocked = true
            persistUnlocked(true)

            // Migrate existing plaintext DB (no-op if already encrypted)
            SQLCipherBridge.shared.migratePlaintextIfNeeded(withKey: key)

            SQLCipherBridge.shared.openWithKey(key)
            VaultFileMigration.schedule()

            // Notify usage tracker so it can retroactively create a pending session
            UsageTracker.shared.onVaultUnlocked()
            IngestQueue.shared.startIngestIfNeeded()
            scheduleInactivityTimer()
            await AppState.shared.resumeAudioAfterVaultUnlockIfNeeded()
        } catch {
            fputs("[VaultManager] unlock failed: \(error.localizedDescription)\n", stderr)
            // Keep locked
        }
    }

    func lock() async {
        guard isUnlocked, !lockInProgress else { return }
        lockInProgress = true
        await AppState.shared.pauseAudioForVaultLock()
        await AudioSegmentProcessor.shared.pauseForVaultLock()
        performLock()
        lockInProgress = false
    }

    func lockAfterCaptureStoppedForTermination() {
        performLock()
    }

    private func performLock() {
        guard isUnlocked else { return }
        isUnlocked = false
        persistUnlocked(false)
        ThumbnailCache.shared.clear()
        IngestQueue.shared.stop()
        SQLCipherBridge.shared.close()
        KeyStore.shared.forgetSession()
        EmbeddingANNIndexStore.shared.clearMemory()
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    func incrementQueuedCount() {
        queuedCount += 1
        UserDefaults.standard.set(queuedCount, forKey: "vault.queuedCount")
    }

    func setQueuedCount(_ n: Int) {
        queuedCount = max(0, n)
        UserDefaults.standard.set(queuedCount, forKey: "vault.queuedCount")
    }

    private func persistUnlocked(_ v: Bool) {
        StoragePaths.setShared(UUID().uuidString, forKey: "vault.mediaGeneration")
        // Write to both standard and App Group so UI and helper processes agree
        let std = UserDefaults.standard
        std.set(v, forKey: "vault.isUnlocked")
        std.synchronize()
        StoragePaths.setShared(v, forKey: "vault.isUnlocked")
        StoragePaths.synchronizeShared()
        DistributedNotificationCenter.default().postNotificationName(VaultMediaAccess.didChange, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func scheduleInactivityTimer() {
        inactivityTimer?.invalidate()
        let d = UserDefaults.standard
        let minutes = d.integer(forKey: "settings.autoLockInactivityMinutes")
        guard minutes > 0 else { return }
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.lock() }
        }
    }
}
