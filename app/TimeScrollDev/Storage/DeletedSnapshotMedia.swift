import Foundation

/// Decides which media files go with a deleted snapshot row. In HEVC mode every snapshot of a
/// minute shares one segment file, so the segment goes only once no remaining row references it.
/// Pure, so it is tested without touching real data.
enum DeletedSnapshotMedia {
    /// Capture may still append to the segment of a snapshot this recent; deleting it would lose the
    /// rest of that minute. Such a segment is left for `OrphanSegmentSweeper` once it is unreferenced.
    static let openSegmentGraceMs: Int64 = 2 * 60_000

    /// - Parameter isReferenced: whether a remaining row still uses the file (for a segment, either
    ///   its .mov or .tse); called after the row is deleted.
    static func filesToRemove(
        path: String?,
        thumbPath: String?,
        startedAtMs: Int64,
        nowMs: Int64,
        isReferenced: (String) -> Bool
    ) -> [String] {
        var files: [String] = []
        if let path, !path.isEmpty, !isReferenced(path) {
            let isSegment = OrphanSegmentPlanner.stem(ofFileName: (path as NSString).lastPathComponent) != nil
            if !isSegment || nowMs - startedAtMs >= openSegmentGraceMs {
                files.append(path)
            }
        }
        if let thumbPath, !thumbPath.isEmpty, thumbPath != path, !isReferenced(thumbPath) {
            files.append(thumbPath)
        }
        return files
    }

    /// The paths a remaining row may use for the same media: a segment's .mov and .tse share a stem.
    static func equivalentPaths(of path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        guard let stem = OrphanSegmentPlanner.stem(ofFileName: name) else { return [path] }
        let dir = (path as NSString).deletingLastPathComponent as NSString
        return [path, dir.appendingPathComponent("\(stem).mov"), dir.appendingPathComponent("\(stem).tse")]
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
