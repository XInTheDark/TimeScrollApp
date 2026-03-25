import Foundation
import AppKit

extension StoragePaths {
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
        if let bd = sharedData(forKey: bookmarkKey) {
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
        if let bd = sharedData(forKey: backupBookmarkKey) {
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
        if let bd = sharedData(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private static func stopBackupAccess() {
        if let bd = sharedData(forKey: backupBookmarkKey) {
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
            setShared(data, forKey: bookmarkKey)
            setShared(url.path, forKey: storageDisplayPathKey)
            synchronizeShared()
        }
        // Write diagnostics marker in the App Group
        let tmpMarker = groupMarkerFile.appendingPathExtension("tmp")
        try? (url.path + "\n").write(to: tmpMarker, atomically: true, encoding: .utf8)
        let _ = try? FileManager.default.replaceItemAt(groupMarkerFile, withItemAt: tmpMarker)
        // Best-effort: ensure default root exists and write a plaintext marker usable by helpers
        try? FileManager.default.createDirectory(at: defaultRoot(), withIntermediateDirectories: true)
        try? (url.path + "\n").write(to: markerFile, atomically: true, encoding: .utf8)
    }

    /// Update the selected backup folder, storing a security-scoped bookmark and user-visible path.
    @MainActor
    static func setBackupFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            setShared(data, forKey: backupBookmarkKey)
            setShared(url.path, forKey: backupDisplayPathKey)
            synchronizeShared()
        }
    }

    /// Clear backup folder configuration.
    @MainActor
    static func clearBackupFolder() {
        removeSharedObject(forKey: backupBookmarkKey)
        removeSharedObject(forKey: backupDisplayPathKey)
        synchronizeShared()
    }

    /// Returns a user-visible description of the current storage root.
    static func displayPath() -> String {
        if let s = sharedString(forKey: storageDisplayPathKey), !s.isEmpty {
            let normalized = normalizeStoragePathIfNeeded(s)
            if normalized != s {
                setShared(normalized, forKey: storageDisplayPathKey)
                synchronizeShared()
            }
            return normalized
        }
        return currentRoot().path
    }

    /// Returns a user-visible description of the backup root.
    static func backupDisplayPath() -> String {
        if let s = sharedString(forKey: backupDisplayPathKey), !s.isEmpty { return s }
        return "Not set"
    }

}
