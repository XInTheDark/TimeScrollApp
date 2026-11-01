import Foundation

/// Decides which HEVC segment files no snapshot row references. Pure, so it is tested without
/// touching real data. Every rule errs toward keeping a file.
enum OrphanSegmentPlanner {
    struct SegmentFile: Equatable {
        let url: URL
        let modifiedAt: Date
    }

    /// Files written this recently are kept: the open segment, or one whose row is not committed yet.
    static let minimumAge: TimeInterval = 15 * 60
    /// More orphans than this points to a replaced or damaged database, not leftovers, so nothing is removed.
    static let maxOrphanFraction = 0.5

    /// "seg-2026-10-30-21-00-00-d1" for a segment file name (.mov or .tse); nil for any other file.
    /// A sealed .tse and its retained live .mov share a stem, so a reference to either keeps both.
    static func stem(ofFileName name: String) -> String? {
        // String slicing only: building a file URL from a bare name stats the disk.
        guard name.hasPrefix("seg-"), let dot = name.lastIndex(of: ".") else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        guard ext == "mov" || ext == "tse" else { return nil }
        return String(name[..<dot])
    }

    static func orphans(in files: [SegmentFile], referencedStems: Set<String>, now: Date) -> [URL] {
        // No references at all means an empty or unreadable database, never "everything is orphaned".
        guard !referencedStems.isEmpty else { return [] }
        var segmentCount = 0
        var orphans: [URL] = []
        for file in files {
            guard let stem = stem(ofFileName: file.url.lastPathComponent) else { continue }
            segmentCount += 1
            if !referencedStems.contains(stem), now.timeIntervalSince(file.modifiedAt) >= minimumAge {
                orphans.append(file.url)
            }
        }
        guard Double(orphans.count) <= Double(segmentCount) * maxOrphanFraction else { return [] }
        return orphans
    }
}
