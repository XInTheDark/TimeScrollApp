import Foundation
import AppKit

final class Compactor {
    private let encoder = ImageEncoder()

    private struct CompactionSettings {
        let degradeAfterDays: Int
        let storageFormatRaw: String
        let degradeMaxLongEdge: Int
        let degradeQuality: Double

        var profile: String {
            "v1|\(storageFormatRaw)|\(degradeMaxLongEdge)|\(String(format: "%.4f", degradeQuality))"
        }
    }

    private func loadSettings() -> CompactionSettings {
        let d = UserDefaults.standard
        let days = d.object(forKey: "settings.degradeAfterDays") != nil ? d.integer(forKey: "settings.degradeAfterDays") : 7
        let fmt = d.string(forKey: "settings.storageFormat") ?? SettingsStore.defaultStorageFormat.rawValue
        let maxEdge = d.object(forKey: "settings.degradeMaxLongEdge") != nil ? d.integer(forKey: "settings.degradeMaxLongEdge") : SettingsStore.defaultDegradeMaxLongEdge
        let quality = d.object(forKey: "settings.degradeQuality") != nil ? d.double(forKey: "settings.degradeQuality") : SettingsStore.defaultDegradeQuality
        return CompactionSettings(degradeAfterDays: days, storageFormatRaw: fmt, degradeMaxLongEdge: maxEdge, degradeQuality: quality)
    }

    @discardableResult
    func compactOlderSnapshots() throws -> Bool {
        let s = loadSettings()
        let days = s.degradeAfterDays
        guard days > 0 else { return false }
        let cutoff = Int64(Date().addingTimeInterval(-Double(days)*86400).timeIntervalSince1970 * 1000)
        // Compaction only degrades still images. HEVC segments are never deleted here:
        // removing data is the job of retention (`settings.retentionDays`), not compaction.
        let profile = s.profile
        let paths = try DB.shared.pathsNeedingCompaction(cutoffMs: cutoff, profile: profile)
        for path in paths {
            var cgImage: CGImage?
            autoreleasepool {
                if let img = NSImage(contentsOfFile: path),
                   let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    cgImage = cg
                }
            }
            guard let cg = cgImage else { continue }
            autoreleasepool {
                do {
                    let format = Self.stillImageFormat(forStorageFormat: s.storageFormatRaw)
                    let encoded = try encoder.encode(
                        cgImage: cg,
                        format: format,
                        maxLongEdge: s.degradeMaxLongEdge,
                        quality: s.degradeQuality
                    )
                    let url = URL(fileURLWithPath: path)
                    let tmp = url.appendingPathExtension("tmp")
                    try encoded.data.write(to: tmp, options: .atomic)
                    let _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? Int64(encoded.data.count)
                    DB.shared.updateSnapshotMeta(path: path, bytes: bytes, width: encoded.width, height: encoded.height, format: encoded.format)
                    DB.shared.markCompacted(path: path, profile: profile)
                } catch {
                }
            }
        }
        return true
    }

    /// Still images keep a still-image format even when new captures are recorded as HEVC video.
    private static func stillImageFormat(forStorageFormat raw: String) -> SettingsStore.StorageFormat {
        let format = SettingsStore.StorageFormat(rawValue: raw) ?? .heic
        return format == .hevc ? .heic : format
    }
}
