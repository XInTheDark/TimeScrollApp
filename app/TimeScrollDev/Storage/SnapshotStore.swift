import Foundation
import AppKit

final class SnapshotStore {
    static let shared = SnapshotStore()
    private init() {}

    private let fm = FileManager.default

    var snapshotsDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TimeScroll/Snapshots", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func saveEncoded(_ encoded: EncodedImage, timestampMs: Int64, formatExt: String) throws -> (url: URL, bytes: Int64) {
        let day = Date(timeIntervalSince1970: TimeInterval(timestampMs)/1000)
        let subdir = snapshotsDir.appendingPathComponent(Self.dayFormatter.string(from: day), isDirectory: true)
        if !fm.fileExists(atPath: subdir.path) {
            try? fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        }
        // Ensure unique filename even when multiple monitors save at the same ms
        var candidate = subdir.appendingPathComponent("snap-\(timestampMs).\(formatExt)")
        if fm.fileExists(atPath: candidate.path) {
            var idx = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = subdir.appendingPathComponent("snap-\(timestampMs)-\(idx).\(formatExt)")
                idx += 1
            }
        }
        let url = candidate
        let tmp = url.appendingPathExtension("tmp")
        try encoded.data.write(to: tmp, options: .atomic)
        let _ = try fm.replaceItemAt(url, withItemAt: tmp)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? Int64(encoded.data.count)
        return (url, size)
    }
}

private extension SnapshotStore {
    static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}
