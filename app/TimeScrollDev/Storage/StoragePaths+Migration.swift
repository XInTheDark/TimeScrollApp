import Foundation
import AppKit

extension StoragePaths {
    /// Legacy default root in Application Support (for migration).
    static func legacyDefaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TimeScroll", isDirectory: true)
    }

    static func legacyUnmanagedSharedSupportRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/\(appGroupID)", isDirectory: true)
    }

    static func normalizedStoredRootURL() -> URL? {
        guard let raw = sharedString(forKey: storageDisplayPathKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizeStoragePathIfNeeded(trimmed)
        if normalized != trimmed {
            setShared(normalized, forKey: storageDisplayPathKey)
            synchronizeShared()
        }
        return URL(fileURLWithPath: normalized, isDirectory: true)
    }

    static func normalizeStoragePathIfNeeded(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if isLegacySandboxPath(path) {
            return defaultRoot().path
        }
        if isLegacyUnmanagedGroupContainerPath(path) {
            return defaultRoot().path
        }
        return path
    }

    private static func isLegacySandboxPath(_ path: String) -> Bool {
        let legacy = legacyDefaultRoot().path
        if path == legacy { return true }
        return path.contains("/Library/Containers/com.muzhen.TimeScroll/")
    }

    private static func isLegacyUnmanagedGroupContainerPath(_ path: String) -> Bool {
        let legacy = legacyUnmanagedSharedSupportRoot().path
        return path == legacy || path.hasPrefix(legacy + "/")
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

    // Synchronize per-app defaults into the shared App Group defaults so helpers see the same settings.
    @MainActor
    static func syncSharedDefaultsFromStandard() {
        let std = UserDefaults.standard
        if sharedData(forKey: bookmarkKey) == nil, let bd = std.data(forKey: bookmarkKey) {
            setShared(bd, forKey: bookmarkKey)
        }
        if sharedString(forKey: storageDisplayPathKey) == nil, let s = std.string(forKey: storageDisplayPathKey) {
            setShared(normalizeStoragePathIfNeeded(s), forKey: storageDisplayPathKey)
        }
        if sharedData(forKey: backupBookmarkKey) == nil, let bd = std.data(forKey: backupBookmarkKey) {
            setShared(bd, forKey: backupBookmarkKey)
        }
        if sharedString(forKey: backupDisplayPathKey) == nil, let s = std.string(forKey: backupDisplayPathKey) {
            setShared(s, forKey: backupDisplayPathKey)
        }
        if sharedObject(forKey: "settings.fuzziness") == nil, let fuzziness = std.string(forKey: "settings.fuzziness") {
            setShared(fuzziness, forKey: "settings.fuzziness")
        }
        if sharedObject(forKey: "settings.intelligentAccuracy") == nil,
           std.object(forKey: "settings.intelligentAccuracy") != nil {
            setShared(std.bool(forKey: "settings.intelligentAccuracy"), forKey: "settings.intelligentAccuracy")
        }
        if sharedObject(forKey: "settings.aiEmbeddingsEnabled") == nil,
           std.object(forKey: "settings.aiEmbeddingsEnabled") != nil {
            setShared(std.bool(forKey: "settings.aiEmbeddingsEnabled"), forKey: "settings.aiEmbeddingsEnabled")
        }
        if sharedObject(forKey: "settings.vaultEnabled") == nil,
           std.object(forKey: "settings.vaultEnabled") != nil {
            setShared(std.bool(forKey: "settings.vaultEnabled"), forKey: "settings.vaultEnabled")
        }
        synchronizeShared()

        // Also write the App Group marker for diagnostics
        if let s = sharedString(forKey: storageDisplayPathKey) {
            let tmp = groupMarkerFile.appendingPathExtension("tmp")
            try? (s + "\n").write(to: tmp, atomically: true, encoding: .utf8)
            let _ = try? FileManager.default.replaceItemAt(groupMarkerFile, withItemAt: tmp)
        }
    }

    static func ensureStorageDisplayPathRecorded() {
        let existing = sharedString(forKey: storageDisplayPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing == nil || existing?.isEmpty == true {
            let path = defaultRoot().path
            setShared(path, forKey: storageDisplayPathKey)
            synchronizeShared()
        }
    }
}
