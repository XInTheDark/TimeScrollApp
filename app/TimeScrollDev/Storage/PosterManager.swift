import Foundation

enum PosterManager {
    private static let fm = FileManager.default

    static func cleanupSegment(startMs: Int64, endMs: Int64) {
        // Fetch rows that still have posters in this time window
        let rows = (try? DB.shared.rowsWithThumbs(startMs: startMs, endMs: endMs)) ?? []
        guard !rows.isEmpty else { return }
        StoragePaths.withSecurityScope {
            for (id, path) in rows {
                // Remove file best-effort, then clear DB pointer
                let u = URL(fileURLWithPath: path)
                _ = try? fm.removeItem(at: u)
                DB.shared.updateThumbPath(rowId: id, thumbPath: nil)
            }
        }
    }
}

