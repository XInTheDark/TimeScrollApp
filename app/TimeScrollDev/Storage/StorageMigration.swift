import Foundation
import AppKit

enum StorageMigrationError: Error { case failedToCreateDestination }

@MainActor
final class StorageMigrationManager {
    static let shared = StorageMigrationManager()
    private init() {}

    /// Change storage folder to `newRoot`. Optionally move existing data and/or delete the old location.
    /// This method coordinates stopping capture, closing DB, moving files, updating settings, and reopening services.
    func changeLocation(to newRoot: URL, moveExisting: Bool, deleteOld: Bool, onProgress: ((String) -> Void)? = nil) async {
        let oldRoot = StoragePaths.currentRoot()
        // If selecting the exact same location, treat as no-op except persisting bookmark
        let same = Self.normalizedPath(of: oldRoot) == Self.normalizedPath(of: newRoot)
        if same {
            onProgress?("Location unchanged")
            // Persist bookmark if reset to default was used (no bookmark previously)
            StoragePaths.setStorageFolder(newRoot)
            if deleteOld { print("[Storage][INFO] Ignoring delete-old: new location equals current location") }
            return
        }

        onProgress?("Preparing…")
        let wasCapturing = AppState.shared.isCapturing
        await AppState.shared.stopCaptureIfNeeded()
        IngestQueue.shared.stop()
        SQLCipherBridge.shared.close()

        let fm = FileManager.default

        // Ensure we can access both old and new (security scope for old; NSOpenPanel grants new)
        var newAccessStarted = false
        if newRoot.startAccessingSecurityScopedResource() { newAccessStarted = true }

        // Create destination root if needed
        do {
            if !fm.fileExists(atPath: newRoot.path) {
                try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
            }
        } catch {
            onProgress?("Failed to create destination")
            if newAccessStarted { newRoot.stopAccessingSecurityScopedResource() }
            return
        }

        // Move/copy data
        if moveExisting {
            onProgress?("Moving data…")
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    StoragePaths.withSecurityScope {
                        do {
                            try Self.transfer(from: oldRoot, to: newRoot)
                        } catch {
                            // Best-effort; continue
                        }
                    }
                    cont.resume()
                }
            }
        }

        // Persist new location bookmark + display path
        StoragePaths.setStorageFolder(newRoot)

        // Optionally delete old location (if it still exists)
        if deleteOld {
            onProgress?("Cleaning up old location…")
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    StoragePaths.withSecurityScope {
                        let fm2 = FileManager.default
                        if fm2.fileExists(atPath: oldRoot.path) {
                            _ = try? fm2.removeItem(at: oldRoot)
                        }
                    }
                    cont.resume()
                }
            }
        }

        if newAccessStarted { newRoot.stopAccessingSecurityScopedResource() }

        // Reopen DB and restart services
        let d = UserDefaults.standard
        let vaultOn = (d.object(forKey: "settings.vaultEnabled") != nil) ? d.bool(forKey: "settings.vaultEnabled") : false
        let unlocked = d.bool(forKey: "vault.isUnlocked")
        if vaultOn && unlocked {
            SQLCipherBridge.shared.openWithUnwrappedKeySilently()
            IngestQueue.shared.startIngestIfNeeded()
        } else {
            _ = try? DB.shared.openIfNeeded()
        }
        if wasCapturing { await AppState.shared.startCaptureIfNeeded() }
        onProgress?("Done")
    }

    // MARK: - Private helpers
    nonisolated private static func transfer(from oldRoot: URL, to newRoot: URL) throws {
        let fm = FileManager.default
        // Move or copy specific entries
        let entries: [String] = [
            "db.sqlite", "db.sqlite-wal", "db.sqlite-shm",
            "Snapshots",
            "IngestQueue",
            "Vault"
        ]
        for name in entries {
            let src = oldRoot.appendingPathComponent(name)
            let dst = newRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                if fm.fileExists(atPath: dst.path) { _ = try? fm.removeItem(at: dst) }
                do {
                    _ = try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                } catch {
                    // Cross-volume move or other issue: fallback to copy-then-remove
                    try copyItem(src: src, dst: dst)
                    if Self.normalizedPath(of: src) != Self.normalizedPath(of: dst) {
                        _ = try? fm.removeItem(at: src)
                    }
                }
            }
        }
    }

    nonisolated private static func copyItem(src: URL, dst: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for i in items {
                try copyItem(src: i, dst: dst.appendingPathComponent(i.lastPathComponent))
            }
        } else {
            let parent = dst.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
            let tmp = dst.appendingPathExtension("tmp")
            if fm.fileExists(atPath: tmp.path) { _ = try? fm.removeItem(at: tmp) }
            try fm.copyItem(at: src, to: tmp)
            let _ = try fm.replaceItemAt(dst, withItemAt: tmp)
        }
    }

    nonisolated private static func normalizedPath(of url: URL) -> String {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
