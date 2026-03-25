import Foundation

extension StoragePaths {
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
    static func refreshBookmark(for url: URL) -> Bool {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            setShared(data, forKey: bookmarkKey)
            return true
        }
        return false
    }

    @discardableResult
    static func refreshBackupBookmark(for url: URL) -> Bool {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            setShared(data, forKey: backupBookmarkKey)
            return true
        }
        return false
    }
}
