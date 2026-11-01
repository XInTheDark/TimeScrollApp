import Foundation

/// Removes HEVC segment files no snapshot row references. Older capture code opened a segment
/// for frames it skipped as near-duplicates, and retention only deletes media of rows it removes,
/// so those files were never cleaned up. Runs from storage maintenance at most once a day.
enum OrphanSegmentSweeper {
    private static let lastRunKey = "maintenance.lastOrphanSegmentSweepAtMs"
    private static let intervalMs: Int64 = 24 * 60 * 60 * 1000

    /// Returns how many files were removed (or moved to the backup folder when backup is on).
    @discardableResult
    static func sweepIfDue(now: Date = Date()) -> Int {
        let defaults = UserDefaults.standard
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard nowMs - Int64(defaults.double(forKey: lastRunKey)) >= intervalMs else { return 0 }
        // Rows captured while the vault was locked wait in the ingest queue; their segments are
        // referenced only once ingested.
        guard !hasPendingIngest() else { return 0 }
        guard let referenced = try? DB.shared.referencedSegmentStems(),
              let files = segmentFiles() else { return 0 }

        let orphans = OrphanSegmentPlanner.orphans(in: files, referencedStems: referenced, now: now)
        let fm = FileManager.default
        var removed = 0
        StoragePaths.withSecurityScope {
            for url in orphans where StoragePaths.archiveSnapshotToBackupIfEnabled(url) || (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        defaults.set(Double(nowMs), forKey: lastRunKey)
        return removed
    }

    private static func hasPendingIngest() -> Bool {
        StoragePaths.withSecurityScope {
            let entries = (try? FileManager.default.contentsOfDirectory(at: StoragePaths.ingestQueueDir(), includingPropertiesForKeys: nil)) ?? []
            return entries.contains { $0.pathExtension == "iq1" }
        }
    }

    /// Nil when the folder cannot be listed, so a failure never looks like an empty folder.
    private static func segmentFiles() -> [OrphanSegmentPlanner.SegmentFile]? {
        StoragePaths.withSecurityScope {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: StoragePaths.videosDir(),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            return urls.compactMap { url in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return OrphanSegmentPlanner.SegmentFile(url: url, modifiedAt: modified)
            }
        }
    }
}
