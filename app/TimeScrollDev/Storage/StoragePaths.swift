import Foundation
import AppKit

/// Centralized file locations for DB, snapshots, vault and queues.
/// Resolves to a user-selected folder if configured (via security-scoped bookmark),
/// otherwise defaults to Application Support/TimeScroll.
enum StoragePaths {
    // UserDefaults keys (also used by background workers)
    static let bookmarkKey = "settings.storageFolderBookmark"
    static let displayPathKey = "settings.storageFolderPath"
    // Backup (external) storage keys
    static let backupBookmarkKey = "settings.backupFolderBookmark"
    static let backupDisplayPathKey = "settings.backupFolderPath"

    /// Returns the current storage root URL. If a security-scoped bookmark is stored,
    /// this resolves it; otherwise returns ~/Library/Application Support/TimeScroll.
    static func currentRoot() -> URL {
        let d = UserDefaults.standard
        if let bd = d.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale {
                    // Refresh bookmark if stale
                    _ = refreshBookmark(for: url)
                }
                return url
            }
        }
        return defaultRoot()
    }

    /// Default root in Application Support.
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TimeScroll", isDirectory: true)
    }

    /// Returns the URL for the SQLite database file under the current root.
    static func dbURL() -> URL { currentRoot().appendingPathComponent("db.sqlite") }

    /// Snapshots directory under the current root.
    static func snapshotsDir() -> URL { currentRoot().appendingPathComponent("Snapshots", isDirectory: true) }

    /// HEVC video chunks directory under the current root.
    static func videosDir() -> URL { currentRoot().appendingPathComponent("Videos", isDirectory: true) }

    /// Encrypted HEVC segments directory under the current root.
    /// As of the simplified design, encrypted and plaintext segments share the same Videos/ folder.
    static func videosEncDir() -> URL { videosDir() }

    /// Ingest queue directory under the current root (for encrypted mode).
    static func ingestQueueDir() -> URL { currentRoot().appendingPathComponent("IngestQueue", isDirectory: true) }

    /// Vault directory under the current root (keys and related state).
    static func vaultDir() -> URL { currentRoot().appendingPathComponent("Vault", isDirectory: true) }

    // MARK: - Backup (external) storage helpers
    /// Returns the configured backup root if set; otherwise nil.
    static func backupRoot() -> URL? {
        let d = UserDefaults.standard
        guard let bd = d.data(forKey: backupBookmarkKey) else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            if stale {
                _ = refreshBackupBookmark(for: url)
            }
            return url
        }
        return nil
    }

    /// Snapshots directory under the backup root. Returns nil if no backup root configured.
    static func backupSnapshotsDir() -> URL? { backupRoot()?.appendingPathComponent("Snapshots", isDirectory: true) }

    /// Ensure backup root exists (and intermediate directories). No-op if not configured.
    static func ensureBackupRootExists() throws {
        guard let root = backupRoot() else { return }
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    /// Ensures the root directory exists (and intermediate directories), returning it.
    @discardableResult
    static func ensureRootExists() throws -> URL {
        let root = currentRoot()
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// Perform work with security scope active if the root uses a bookmark. Always stops access afterwards.
    static func withSecurityScope<T>(_ body: () throws -> T) rethrows -> T {
        let d = UserDefaults.standard
        var started = false
        if let bd = d.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale { _ = refreshBookmark(for: url) }
                started = url.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if started {
                // Stop access on the main thread to avoid rare AppKit assertions
                if Thread.isMainThread { stopAccess() } else { DispatchQueue.main.async { stopAccess() } }
            }
        }
        return try body()
    }

    /// Perform work with backup security scope active if the backup root uses a bookmark. Always stops access afterwards.
    static func withBackupSecurityScope<T>(_ body: () throws -> T) rethrows -> T {
        let d = UserDefaults.standard
        var started = false
        if let bd = d.data(forKey: backupBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale { _ = refreshBackupBookmark(for: url) }
                started = url.startAccessingSecurityScopedResource()
            }
        }
        defer {
            if started {
                if Thread.isMainThread { stopBackupAccess() } else { DispatchQueue.main.async { stopBackupAccess() } }
            }
        }
        return try body()
    }

    private static func stopAccess() {
        let d = UserDefaults.standard
        if let bd = d.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private static func stopBackupAccess() {
        let d = UserDefaults.standard
        if let bd = d.data(forKey: backupBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Update the selected storage folder, storing a security-scoped bookmark and user-visible path.
    /// Callers should stop capture/close DB before invoking migration operations.
    @MainActor
    static func setStorageFolder(_ url: URL) {
        // Persist bookmark + display path
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            let d = UserDefaults.standard
            d.set(data, forKey: bookmarkKey)
            d.set(url.path, forKey: displayPathKey)
            d.synchronize()
        }
    }

    /// Update the selected backup folder, storing a security-scoped bookmark and user-visible path.
    @MainActor
    static func setBackupFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            let d = UserDefaults.standard
            d.set(data, forKey: backupBookmarkKey)
            d.set(url.path, forKey: backupDisplayPathKey)
            d.synchronize()
        }
    }

    /// Clear backup folder configuration.
    @MainActor
    static func clearBackupFolder() {
        let d = UserDefaults.standard
        d.removeObject(forKey: backupBookmarkKey)
        d.removeObject(forKey: backupDisplayPathKey)
        d.synchronize()
    }

    /// Returns a user-visible description of the current storage root.
    static func displayPath() -> String {
        let d = UserDefaults.standard
        if let s = d.string(forKey: displayPathKey), !s.isEmpty { return s }
        return currentRoot().path
    }

    /// Returns a user-visible description of the backup root.
    static func backupDisplayPath() -> String {
        let d = UserDefaults.standard
        if let s = d.string(forKey: backupDisplayPathKey), !s.isEmpty { return s }
        return "Not set"
    }

    // MARK: - Snapshot archiving (Backup)
    /// Moves a snapshot file to the configured backup location if backup is enabled.
    /// - Returns: true if the file was archived to backup; false if backup disabled/unset or move failed.
    static func archiveSnapshotToBackupIfEnabled(_ sourceURL: URL) -> Bool {
        // Snapshot flags/state from UserDefaults for background safety
        let d = UserDefaults.standard
        let enabled = (d.object(forKey: "settings.backupEnabled") != nil) ? d.bool(forKey: "settings.backupEnabled") : false
        guard enabled, backupRoot() != nil else { return false }

        // Compute destination directory: Backup/Snapshots/(yyyy-MM-dd)?
        let destRootOpt = backupSnapshotsDir()
        guard let destRoot = destRootOpt else { return false }

        // Preserve day subdirectory when available (matches yyyy-MM-dd)
        let parentName = sourceURL.deletingLastPathComponent().lastPathComponent
        let dayPattern = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
        let isDay = dayPattern?.firstMatch(in: parentName, range: NSRange(location: 0, length: parentName.count)) != nil
        let destDir = (isDay ? destRoot.appendingPathComponent(parentName, isDirectory: true) : destRoot)

        do {
            try ensureBackupRootExists()
        } catch {
            return false
        }

        // Perform under both security scopes
        return withSecurityScope { () -> Bool in
            return withBackupSecurityScope { () -> Bool in
                let fm = FileManager.default
                if !fm.fileExists(atPath: destDir.path) {
                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                }
                let destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)
                return atomicMoveOrCopyReplace(src: sourceURL, dest: destURL)
            }
        }
    }

    /// Copy to a temp at destination then atomically replace; fallback to move when copy fails.
    /// Returns true on success.
    private static func atomicMoveOrCopyReplace(src: URL, dest: URL) -> Bool {
        let fm = FileManager.default
        let tmp = dest.appendingPathExtension("tmp")
        do {
            if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
            try fm.copyItem(at: src, to: tmp)
            let _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            _ = try? fm.removeItem(at: src)
            return true
        } catch {
            // Fallback: direct move (non-atomic across volumes, but acceptable as fallback)
            do {
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: src, to: dest)
                return true
            } catch {
                return false
            }
        }
    }

    /// Refreshes bookmark data for a given URL and stores it.
    @discardableResult
    private static func refreshBookmark(for url: URL) -> Bool {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            return true
        }
        return false
    }

    @discardableResult
    private static func refreshBackupBookmark(for url: URL) -> Bool {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: backupBookmarkKey)
            return true
        }
        return false
    }
}
