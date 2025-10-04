import Foundation
import AppKit

/// Centralized file locations for DB, snapshots, vault and queues.
/// Resolves to a user-selected folder if configured (via security-scoped bookmark),
/// otherwise defaults to Application Support/TimeScroll.
enum StoragePaths {
    // UserDefaults keys (also used by background workers)
    static let bookmarkKey = "settings.storageFolderBookmark"
    static let displayPathKey = "settings.storageFolderPath"

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

    /// Ingest queue directory under the current root (for encrypted mode).
    static func ingestQueueDir() -> URL { currentRoot().appendingPathComponent("IngestQueue", isDirectory: true) }

    /// Vault directory under the current root (keys and related state).
    static func vaultDir() -> URL { currentRoot().appendingPathComponent("Vault", isDirectory: true) }

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

    private static func stopAccess() {
        let d = UserDefaults.standard
        if let bd = d.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.stopAccessingSecurityScopedResource()
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

    /// Returns a user-visible description of the current storage root.
    static func displayPath() -> String {
        let d = UserDefaults.standard
        if let s = d.string(forKey: displayPathKey), !s.isEmpty { return s }
        return currentRoot().path
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
}
