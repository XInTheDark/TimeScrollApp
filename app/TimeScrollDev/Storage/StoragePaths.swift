import Foundation
import AppKit
import Security

/// Centralized file locations for DB, snapshots, vault and queues.
/// Resolves to a user-selected folder if configured (via security-scoped bookmark),
/// otherwise defaults to Application Support/TimeScroll.
enum StoragePaths {
    // UserDefaults keys (also used by background workers)
    static let bookmarkKey = "settings.storageFolderBookmark"
    static let storageDisplayPathKey = "settings.storageFolderPath"
    // Backup (external) storage keys
    static let backupBookmarkKey = "settings.backupFolderBookmark"
    static let backupDisplayPathKey = "settings.backupFolderPath"

    // App Group identifier used when the app is Apple-signed with the matching entitlement.
    // Public/local builds must NOT fall back to ~/Library/Group Containers/... because macOS
    // treats that as protected "other apps' data" and will repeatedly prompt for access.
    static let appGroupID = "group.com.muzhen.TimeScroll.shared"
    static let sharedStateQueue = DispatchQueue(label: "TimeScroll.StoragePaths.SharedState")
    static let sharedStateFilename = "shared-settings.plist"
    static let sharedSubdirectoryName = "Shared"

    // Helper-discoverable marker for active storage root
    static let markerFile: URL = {
        defaultRoot().appendingPathComponent(".storage-root-path.txt")
    }()

    static let groupMarkerFile: URL = {
        let sharedDir = sharedSupportRoot().appendingPathComponent(sharedSubdirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        return sharedDir.appendingPathComponent(".storage-root-path.txt")
    }()

    static func sharedSupportRoot() -> URL {
        if let container = managedAppGroupContainerURL() {
            return container
        }

        let manual = unmanagedSharedSupportRoot()
        if !FileManager.default.fileExists(atPath: manual.path) {
            try? FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        }
        return manual
    }

    private static func unmanagedSharedSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TimeScrollShared", isDirectory: true)
    }

    /// Returns the current storage root URL. If a security-scoped bookmark is stored,
    /// this resolves it; otherwise returns ~/Library/Application Support/TimeScroll.
    static func currentRoot() -> URL {
        if let bd = sharedData(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bd, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale {
                    _ = refreshBookmark(for: url)
                }
                return url
            }
        }
        if let stored = normalizedStoredRootURL() {
            return stored
        }
        return defaultRoot()
    }

    /// Default root under the managed App Group container when available,
    /// otherwise under the manually-managed shared directory.
    static func defaultRoot() -> URL {
        let base = sharedSupportRoot()
        fputs("[StoragePaths] Using shared support root: \(base.path)\n", stderr)
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

    /// ANN/vector index cache directory under the current root.
    static func vectorIndexDir() -> URL { currentRoot().appendingPathComponent("VectorIndex", isDirectory: true) }

    /// Shared Vault directory used by both the main app and the MCP helper.
    static func sharedVaultDir() -> URL {
        sharedSupportRoot().appendingPathComponent("Vault", isDirectory: true)
    }

    static func managedAppGroupContainerURL() -> URL? {
        guard canUseManagedAppGroupAccess() else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func canUseManagedAppGroupAccess() -> Bool {
        hasValidTeamIdentifier() && hasManagedAppGroupEntitlement()
    }

    static func hasManagedAppGroupEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) else {
            return false
        }

        if let groups = value as? [String] {
            return groups.contains(appGroupID)
        }

        if CFGetTypeID(value) == CFArrayGetTypeID() {
            let cfArray = unsafeBitCast(value, to: CFArray.self)
            for index in 0..<CFArrayGetCount(cfArray) {
                if let raw = CFArrayGetValueAtIndex(cfArray, index) {
                    let candidate = unsafeBitCast(raw, to: CFString.self) as String
                    if candidate == appGroupID {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// Check if the app is signed with a valid Team Identifier.
    /// Ad-hoc signed apps have no Team ID and can't persist TCC permissions.
    static func hasValidTeamIdentifier() -> Bool {
        guard let bundleURL = Bundle.main.bundleURL as CFURL? else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL, [], &code) == errSecSuccess,
              let staticCode = code else { return false }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signingInfo = info as? [String: Any] else { return false }

        if let teamID = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String, !teamID.isEmpty {
            return true
        }
        return false
    }
}
