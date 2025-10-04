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

    func setVaultEnabled(_ enabled: Bool) {
        isVaultEnabled = enabled
        let d = UserDefaults.standard
        d.set(enabled, forKey: "settings.vaultEnabled")
        d.synchronize()
        if enabled {
            // Close any existing plaintext DB connection so migration can safely replace the file
            DB.shared.close()
            // Ensure key material exists
            try? KeyStore.shared.ensureKEK()
            try? KeyStore.shared.createAndWrapDbKeyIfMissing()
            // Attempt to migrate existing plaintext files to encrypted .tse in the background
            Task.detached { [weak self] in
                await self?.migrateFilesIfNeeded()
            }
        } else {
            // When disabling, perform reverse DB migration so plaintext DB continues to work
            if let key = try? KeyStore.shared.unwrapDbKey() {
                // Ensure DB is closed before replacing the file
                SQLCipherBridge.shared.close()
                SQLCipherBridge.shared.migrateEncryptedToPlaintextIfNeeded(withKey: key)
            }
            lock()
        }
    }

    func unlock(presentingWindow: NSWindow? = nil) async {
        guard isVaultEnabled else { return }
        do {
            _ = try await KeyStore.shared.requestPrivateKeyAccess(presentingWindow: presentingWindow)
            // Unwrap DB key
            let key = try? KeyStore.shared.unwrapDbKey()
            isUnlocked = true
            persistUnlocked(true)
            if let key = key {
                // Migrate existing plaintext DB (no-op if already encrypted)
                SQLCipherBridge.shared.migratePlaintextIfNeeded(withKey: key)
            }
            SQLCipherBridge.shared.openWithUnwrappedKeySilently()
            // Notify usage tracker so it can retroactively create a pending session
            UsageTracker.shared.onVaultUnlocked()
            IngestQueue.shared.startIngestIfNeeded()
            scheduleInactivityTimer()
        } catch {
            // Keep locked
        }
    }

    func lock() {
        guard isUnlocked else { return }
        IngestQueue.shared.stop()
        SQLCipherBridge.shared.close()
        KeyStore.shared.forgetSession()
        ThumbnailCache.shared.clear()
        isUnlocked = false
        persistUnlocked(false)
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
        let d = UserDefaults.standard
        d.set(v, forKey: "vault.isUnlocked")
        d.synchronize()
    }

    private func scheduleInactivityTimer() {
        inactivityTimer?.invalidate()
        let d = UserDefaults.standard
        let minutes = d.integer(forKey: "settings.autoLockInactivityMinutes")
        guard minutes > 0 else { return }
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }
}

extension VaultManager {
    private func migrateFilesIfNeeded() async {
        // Open DB with SQLCipher if possible; otherwise normal open
        SQLCipherBridge.shared.openWithUnwrappedKeySilently()
        guard let rows = try? DB.shared.listPlaintextSnapshots(limit: 10000) else { return }
        if rows.isEmpty { return }
        for row in rows {
            autoreleasepool {
                do {
                    let url = URL(fileURLWithPath: row.path)
                    guard let data = try? Data(contentsOf: url) else { return }
                    // Build EncodedImage approximation for header fields
                    let fmt = url.pathExtension.lowercased()
                    let enc = EncodedImage(data: data, format: fmt == "jpeg" ? "jpg" : fmt, width: 0, height: 0)
                    let encURL = try FileCrypter.shared.encryptSnapshot(encoded: enc, timestampMs: row.startedAtMs)
                    // Replace original file atomically and update DB path
                    _ = try? FileManager.default.removeItem(at: url)
                    try DB.shared.updateSnapshotPath(oldPath: row.path, newPath: encURL.path, bytes: Int64(data.count), format: enc.format)
                } catch {
                    // Skip on error
                }
            }
        }
    }
}
