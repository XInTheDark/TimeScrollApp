import Foundation
import AppKit

/// Centralized file locations for DB, snapshots, vault and queues.
/// Resolves to a user-selected folder if configured (via security-scoped bookmark),
/// otherwise defaults to Application Support/TimeScroll.
enum StoragePaths {
    // UserDefaults keys (also used by background workers)
    static let bookmarkKey = "settings.storageFolderBookmark"
    static let storageDisplayPathKey = "settings.storageFolderPath"
    // Helper-discoverable marker for active storage root
    private static let markerFile: URL = {
        return defaultRoot().appendingPathComponent(".storage-root-path.txt")
    }()
    // Backup (external) storage keys
    static let backupBookmarkKey = "settings.backupFolderBookmark"
    static let backupDisplayPathKey = "settings.backupFolderPath"

    // App Group for sharing preferences with the MCP helper
    static let appGroupID = "group.com.muzhen.TimeScroll.shared"
    static var sharedDefaults: UserDefaults = {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }()
    // Optional: marker in App Group for diagnostics (not a behavioral dependency)
    private static let groupMarkerFile: URL? = {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let sharedDir = container.appendingPathComponent("Shared", isDirectory: true)
            try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            return sharedDir.appendingPathComponent(".storage-root-path.txt")
        }
        return nil
    }()

    /// Returns the current storage root URL. If a security-scoped bookmark is stored,
    /// this resolves it; otherwise returns ~/Library/Application Support/TimeScroll.
    static func currentRoot() -> URL {
        if let bd = sharedDefaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale {
                    // Refresh bookmark if stale
                    _ = refreshBookmark(for: url)
                }
                return url
            }
        }
        if let stored = normalizedStoredRootURL() {
            return stored
        }
        // Note: We previously checked a marker file here. We now prefer defaultRoot() (App Group)
        // to ensure sandboxed helpers can access the default storage.
        return defaultRoot()
    }

    /// Default root in Application Support.
    static func defaultRoot() -> URL {
        // Prefer App Group container for shared access
           if let container = appGroupContainerURL() {
               fputs("[StoragePaths] Using App Group container: \(container.path)\n", stderr)
               return container.appendingPathComponent("TimeScroll", isDirectory: true)
           }
           fputs("[StoragePaths] App Group container not found for \(appGroupID), falling back to sandbox\n", stderr)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TimeScroll", isDirectory: true)
    }
    
    /// Legacy default root in Application Support (for migration).
    static func legacyDefaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TimeScroll", isDirectory: true)
    }

    private static func normalizedStoredRootURL() -> URL? {
        guard let raw = sharedDefaults.string(forKey: storageDisplayPathKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizeStoragePathIfNeeded(trimmed)
        if normalized != trimmed {
            sharedDefaults.set(normalized, forKey: storageDisplayPathKey)
            sharedDefaults.synchronize()
        }
        return URL(fileURLWithPath: normalized, isDirectory: true)
    }

    private static func normalizeStoragePathIfNeeded(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if isLegacySandboxPath(path) {
            return defaultRoot().path
        }
        return path
    }

    private static func isLegacySandboxPath(_ path: String) -> Bool {
        let legacy = legacyDefaultRoot().path
        if path == legacy { return true }
        return path.contains("/Library/Containers/com.muzhen.TimeScroll/")
    }

    /// Returns true when legacy sandbox data exists and should be moved into the App Group for MCP.
    static func needsLegacyMigrationForMCP() -> Bool {
        let legacy = legacyDefaultRoot()
        let shared = defaultRoot()
        let current = currentRoot()
        // Only migrate if we are *currently* still using the legacy sandbox root
        guard current.standardizedFileURL == legacy.standardizedFileURL else { return false }
        guard legacy.standardizedFileURL != shared.standardizedFileURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDir) && isDir.boolValue
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

    /// Shared Vault directory in the App Group container.
    /// This is the preferred location for keys to ensure accessibility by both the main app and extensions.
    static func sharedVaultDir() -> URL {
        if let container = appGroupContainerURL() {
            return container.appendingPathComponent("Vault", isDirectory: true)
        }
        // Fallback to local vault if App Group is unavailable (should not happen in properly configured app)
        return vaultDir()
    }

    private static func appGroupContainerURL() -> URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return url
        }
        let manual = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(appGroupID)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: manual.path) {
            try? FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        }
        return manual
    }

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
        var started = false
        if let bd = sharedDefaults.data(forKey: bookmarkKey) {
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
        var started = false
        if let bd = sharedDefaults.data(forKey: backupBookmarkKey) {
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
        if let bd = sharedDefaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private static func stopBackupAccess() {
        if let bd = sharedDefaults.data(forKey: backupBookmarkKey) {
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
            sharedDefaults.set(data, forKey: bookmarkKey)
            sharedDefaults.set(url.path, forKey: storageDisplayPathKey)
            sharedDefaults.synchronize()
        }
        // Write diagnostics marker in the App Group
        if let m = groupMarkerFile {
            let tmp = m.appendingPathExtension("tmp")
            try? (url.path + "\n").write(to: tmp, atomically: true, encoding: .utf8)
            let _ = try? FileManager.default.replaceItemAt(m, withItemAt: tmp)
        }
        // Best-effort: ensure default root exists and write a plaintext marker usable by helpers
        try? FileManager.default.createDirectory(at: defaultRoot(), withIntermediateDirectories: true)
        try? (url.path + "\n").write(to: markerFile, atomically: true, encoding: .utf8)
    }

    /// Update the selected backup folder, storing a security-scoped bookmark and user-visible path.
    @MainActor
    static func setBackupFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            sharedDefaults.set(data, forKey: backupBookmarkKey)
            sharedDefaults.set(url.path, forKey: backupDisplayPathKey)
            sharedDefaults.synchronize()
        }
    }

    /// Clear backup folder configuration.
    @MainActor
    static func clearBackupFolder() {
        sharedDefaults.removeObject(forKey: backupBookmarkKey)
        sharedDefaults.removeObject(forKey: backupDisplayPathKey)
        sharedDefaults.synchronize()
    }

    /// Returns a user-visible description of the current storage root.
    static func displayPath() -> String {
        if let s = sharedDefaults.string(forKey: storageDisplayPathKey), !s.isEmpty {
            let normalized = normalizeStoragePathIfNeeded(s)
            if normalized != s {
                sharedDefaults.set(normalized, forKey: storageDisplayPathKey)
                sharedDefaults.synchronize()
            }
            return normalized
        }
        return currentRoot().path
    }

    /// Returns a user-visible description of the backup root.
    static func backupDisplayPath() -> String {
        if let s = sharedDefaults.string(forKey: backupDisplayPathKey), !s.isEmpty { return s }
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
            sharedDefaults.set(data, forKey: bookmarkKey)
            return true
        }
        return false
    }

    @discardableResult
    private static func refreshBackupBookmark(for url: URL) -> Bool {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            sharedDefaults.set(data, forKey: backupBookmarkKey)
            return true
        }
        return false
    }

    // Synchronize per-app defaults into the shared App Group defaults so helpers see the same settings.
    @MainActor
    static func syncSharedDefaultsFromStandard() {
        let std = UserDefaults.standard
        if sharedDefaults.data(forKey: bookmarkKey) == nil, let bd = std.data(forKey: bookmarkKey) {
            sharedDefaults.set(bd, forKey: bookmarkKey)
        }
        if sharedDefaults.string(forKey: storageDisplayPathKey) == nil, let s = std.string(forKey: storageDisplayPathKey) {
            sharedDefaults.set(normalizeStoragePathIfNeeded(s), forKey: storageDisplayPathKey)
        }
        if sharedDefaults.data(forKey: backupBookmarkKey) == nil, let bd = std.data(forKey: backupBookmarkKey) {
            sharedDefaults.set(bd, forKey: backupBookmarkKey)
        }
        if sharedDefaults.string(forKey: backupDisplayPathKey) == nil, let s = std.string(forKey: backupDisplayPathKey) {
            sharedDefaults.set(s, forKey: backupDisplayPathKey)
        }
        sharedDefaults.synchronize()

        // Also write the App Group marker for diagnostics
        if let s = sharedDefaults.string(forKey: storageDisplayPathKey), let m = groupMarkerFile {
            let tmp = m.appendingPathExtension("tmp")
            try? (s + "\n").write(to: tmp, atomically: true, encoding: .utf8)
            let _ = try? FileManager.default.replaceItemAt(m, withItemAt: tmp)
        }
    }

    static func ensureStorageDisplayPathRecorded() {
        let existing = sharedDefaults.string(forKey: storageDisplayPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing == nil || existing?.isEmpty == true {
            let path = defaultRoot().path
            sharedDefaults.set(path, forKey: storageDisplayPathKey)
            sharedDefaults.synchronize()
        }
    }
}
