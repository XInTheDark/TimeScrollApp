import Foundation
import LocalAuthentication
import AppKit


@MainActor
final class VaultManager: ObservableObject {
    static let shared = VaultManager()

    @Published private(set) var isVaultEnabled: Bool = false
    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var queuedCount: Int = 0
    /// User-facing description of the last failed enable/unlock attempt.
    @Published var lastError: String?
    /// Set when the keychain has no vault key (new Mac, reset keychain): unlocking then needs
    /// the recovery passphrase.
    @Published private(set) var needsRecoveryPassphrase: Bool = false

    static let minimumPassphraseLength = 8

    private var inactivityTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var lockInProgress = false

    private init() {
        loadPrefs()
        // Observe defaults changes to reflect queued count and unlocked state in UI.
        // Use queue: nil so the posting thread never waits for the main queue: background
        // writers (e.g. the DB queue) would otherwise deadlock against a main thread that is
        // itself blocked on them.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
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

    /// Creates (or re-seals) the vault key, encrypts the database and leaves the vault unlocked.
    @discardableResult
    func enableVault(recoveryPassphrase: String) async -> Bool {
        guard recoveryPassphrase.count >= Self.minimumPassphraseLength else {
            lastError = "The recovery passphrase must be at least \(Self.minimumPassphraseLength) characters."
            return false
        }
        let resumeCapture = AppState.shared.isCapturing
        if resumeCapture { await AppState.shared.stopCaptureIfNeeded() }
        defer { if resumeCapture { Task { await AppState.shared.startCaptureIfNeeded() } } }

        do {
            // Re-enabling keeps an existing secret so media encrypted earlier stays readable.
            let existing = VaultManifest.load()
            let secret: VaultSecret
            if let existing, let stored = try VaultKeychainStore.load(), existing.matches(stored) {
                secret = stored
            } else {
                secret = VaultSecret.generate()
            }
            let manifest = try await Task.detached(priority: .userInitiated) {
                try VaultManifest.make(secret: secret, recoveryPassphrase: recoveryPassphrase)
            }.value
            try manifest.save()
            try VaultKeychainStore.save(secret)

            await AppState.shared.pauseAudioForVaultLock()
            persistVaultEnabled(true)
            // Close the plaintext connection so the file can be migrated to SQLCipher.
            DB.shared.close()
            await finishUnlock(with: secret)
            return true
        } catch {
            fputs("[VaultManager] enable failed: \(error.localizedDescription)\n", stderr)
            lastError = "The encrypted vault could not be enabled. \(error.localizedDescription)"
            return false
        }
    }

    /// Decrypts the database back to plaintext and turns the vault off. The key stays in the
    /// keychain so re-enabling can still read media encrypted earlier.
    func disableVault() async {
        guard isVaultEnabled else { return }
        if !isUnlocked { await unlock() }
        guard isUnlocked, let key = VaultKeys.shared.databaseKey else {
            lastError = "Unlock the vault before turning it off."
            return
        }
        let resumeCapture = AppState.shared.isCapturing
        if resumeCapture { await AppState.shared.stopCaptureIfNeeded() }
        SQLCipherBridge.shared.close()
        SQLCipherBridge.shared.migrateEncryptedToPlaintextIfNeeded(withKey: key)
        performLock()
        persistVaultEnabled(false)
        await AppState.shared.resumeAudioAfterVaultUnlockIfNeeded()
        if resumeCapture { await AppState.shared.startCaptureIfNeeded() }
    }

    /// Unlocks with Touch ID / the login password and the key stored in the keychain.
    func unlock(presentingWindow: NSWindow? = nil) async {
        guard isVaultEnabled, !isUnlocked else { return }
        if await recoverIfVaultWasNeverUsable() { return }
        do {
            try await authenticateUser()
            guard let secret = try VaultKeychainStore.load() else {
                needsRecoveryPassphrase = true
                return
            }
            guard VaultManifest.load()?.matches(secret) ?? false else {
                // The keychain holds a different vault's key; fall back to recovery.
                needsRecoveryPassphrase = true
                return
            }
            await finishUnlock(with: secret)
        } catch {
            fputs("[VaultManager] unlock failed: \(error.localizedDescription)\n", stderr)
            if !Self.isUserCancellation(error) {
                lastError = "The vault could not be unlocked. \(error.localizedDescription)"
            }
        }
    }

    /// Unlocks with the recovery passphrase and restores the key to this Mac's keychain.
    @discardableResult
    func unlock(recoveryPassphrase: String) async -> Bool {
        guard isVaultEnabled, !isUnlocked, let manifest = VaultManifest.load() else { return false }
        do {
            let secret = try await Task.detached(priority: .userInitiated) {
                try manifest.openRecovery(passphrase: recoveryPassphrase)
            }.value
            try VaultKeychainStore.save(secret)
            await finishUnlock(with: secret)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func finishUnlock(with secret: VaultSecret) async {
        VaultKeys.shared.install(secret)
        needsRecoveryPassphrase = false
        isUnlocked = true
        persistUnlocked(true)

        let key = secret.databaseKey
        // Migrate an existing plaintext DB (no-op if already encrypted).
        SQLCipherBridge.shared.migratePlaintextIfNeeded(withKey: key)
        SQLCipherBridge.shared.openWithKey(key)
        VaultFileMigration.schedule()

        // Notify usage tracker so it can retroactively create a pending session
        UsageTracker.shared.onVaultUnlocked()
        IngestQueue.shared.startIngestIfNeeded()
        scheduleInactivityTimer()
        await AppState.shared.resumeAudioAfterVaultUnlockIfNeeded()
    }

    private func authenticateUser() async throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw policyError ?? NSError(domain: "TS.Vault", code: 40, userInfo: [NSLocalizedDescriptionKey: "Authentication is unavailable."])
        }
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock the TimeScroll vault")
    }

    /// A vault without a manifest never got key material. If its database is still plaintext,
    /// nothing was ever encrypted: turn it off so the user is not stuck behind an unlock that
    /// can never succeed. An encrypted database without a manifest comes from the pre-v2 vault.
    private func recoverIfVaultWasNeverUsable() async -> Bool {
        guard VaultManifest.load() == nil else { return false }
        if SQLCipherBridge.shared.isDatabaseEncrypted() {
            lastError = "This vault was created by an older TimeScroll version and cannot be opened by this version."
            return true
        }
        fputs("[VaultManager] vault enabled without key material; disabling\n", stderr)
        persistVaultEnabled(false)
        lastError = "The encrypted vault was turned off because its key was never created. Your existing data was never encrypted and remains available."
        await AppState.shared.resumeAudioAfterVaultUnlockIfNeeded()
        await AppState.shared.restartCaptureIfRunning()
        return true
    }

    private func persistVaultEnabled(_ enabled: Bool) {
        isVaultEnabled = enabled
        SettingsStore.shared.vaultEnabled = enabled
        let d = UserDefaults.standard
        d.set(enabled, forKey: "settings.vaultEnabled")
        StoragePaths.setShared(enabled, forKey: "settings.vaultEnabled")
        d.synchronize()
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == LAError.errorDomain else { return false }
        return [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue].contains(ns.code)
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
        VaultKeys.shared.clearSecret()
        EmbeddingANNIndexStore.shared.clearMemory()
        EmbeddingMatrixStore.shared.clearMemory()
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
