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
        var transferComplete = true
        if moveExisting {
            onProgress?("Moving data…")
            transferComplete = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let moved = StoragePaths.withSecurityScope { () -> Bool in
                        do {
                            return try Self.transfer(from: oldRoot, to: newRoot)
                        } catch {
                            fputs("[StorageMigration] transfer failed: \(error.localizedDescription)\n", stderr)
                            return false
                        }
                    }
                    cont.resume(returning: moved)
                }
            }
        }

        // Persist new location bookmark + display path
        StoragePaths.setStorageFolder(newRoot)

        // After moving files, ensure DB rows which contain absolute on-disk paths are updated
        // to reflect the new root. This ensures older snapshots (whose path values were
        // stored using the old root) continue to resolve after migration.
        if moveExisting {
            // Best-effort: open DB at new root and rewrite any path/thumb_path prefixes.
            do {
                try DB.shared.openIfNeeded()
                DB.shared.updateSnapshotPathsAfterRootMove(oldRoot: oldRoot.path, newRoot: newRoot.path)
            } catch {
                // Non-fatal; log and continue — best-effort migration
                fputs("[StorageMigration] warn: failed to update DB paths after move: \(error.localizedDescription)\n", stderr)
            }
        }

        // Optionally delete old location. Never delete data that failed to move, and in a
        // user-picked folder only remove TimeScroll's own entries, never the folder itself.
        if deleteOld && !transferComplete {
            onProgress?("Some data could not be moved; the previous folder was kept.")
        } else if deleteOld {
            onProgress?("Cleaning up old location…")
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    StoragePaths.withSecurityScope {
                        let fm2 = FileManager.default
                        if StoragePaths.isDefaultRoot(oldRoot) {
                            if fm2.fileExists(atPath: oldRoot.path) {
                                _ = try? fm2.removeItem(at: oldRoot)
                            }
                        } else {
                            for entry in StoragePaths.storageEntries(in: oldRoot) {
                                _ = try? fm2.removeItem(at: entry)
                            }
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
        // The vault manifest moved with the storage root; reload the cached public key from it.
        VaultKeys.shared.reloadPublicKey()
        if vaultOn && unlocked {
            SQLCipherBridge.shared.openForCurrentVaultState()
            IngestQueue.shared.startIngestIfNeeded()
        } else {
            _ = try? DB.shared.openIfNeeded()
        }
        if wasCapturing { await AppState.shared.startCaptureIfNeeded() }
        onProgress?(transferComplete ? "Done" : "Done. Some data could not be moved and was left in the previous folder.")
    }

    // MARK: - Private helpers
    /// Moves the old root's data into `newRoot`, preserving names. Only TimeScroll's own entries
    /// move out of a user-picked folder (see `StoragePaths.storageEntries`). Anything already at
    /// a destination name is set aside rather than deleted. Returns false if any entry failed.
    @discardableResult
    nonisolated static func transfer(from oldRoot: URL, to newRoot: URL) throws -> Bool {
        let fm = FileManager.default
        var allMoved = true
        for src in StoragePaths.storageEntries(in: oldRoot) {
            let dst = newRoot.appendingPathComponent(src.lastPathComponent)
            guard fm.fileExists(atPath: src.path), normalizedPath(of: src) != normalizedPath(of: dst) else { continue }
            do {
                if fm.fileExists(atPath: dst.path) { try setAside(dst) }
                _ = try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try fm.moveItem(at: src, to: dst)
                } catch {
                    // Cross-volume move or other issue: copy, then remove the source only once
                    // the copy is complete.
                    try copyItem(src: src, dst: dst)
                    _ = try? fm.removeItem(at: src)
                }
            } catch {
                fputs("[StorageMigration] could not move \(src.lastPathComponent): \(error.localizedDescription)\n", stderr)
                allMoved = false
            }
        }
        return allMoved
    }

    /// Renames an existing destination entry so a move never overwrites data already there.
    nonisolated private static func setAside(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).replaced-\(stamp)")
        try FileManager.default.moveItem(at: url, to: aside)
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
