import Foundation
import AppKit

final class Compactor {
    private let encoder = ImageEncoder()

    private struct CompactionSettings {
        let degradeAfterDays: Int
        let storageFormatRaw: String
        let degradeMaxLongEdge: Int
        let degradeQuality: Double
    }

    private func loadSettings() -> CompactionSettings {
        let d = UserDefaults.standard
        let days = d.object(forKey: "settings.degradeAfterDays") != nil ? d.integer(forKey: "settings.degradeAfterDays") : 7
        let fmt = d.string(forKey: "settings.storageFormat") ?? "heic"
        let maxEdge = d.object(forKey: "settings.degradeMaxLongEdge") != nil ? d.integer(forKey: "settings.degradeMaxLongEdge") : 1200
        let quality = d.object(forKey: "settings.degradeQuality") != nil ? d.double(forKey: "settings.degradeQuality") : 0.5
        return CompactionSettings(degradeAfterDays: days, storageFormatRaw: fmt, degradeMaxLongEdge: maxEdge, degradeQuality: quality)
    }

    func compactOlderSnapshots() {
        let s = loadSettings()
        let days = s.degradeAfterDays
        guard days > 0 else { return }
        let cutoff = Int64(Date().addingTimeInterval(-Double(days)*86400).timeIntervalSince1970 * 1000)
        let paths = (try? DB.shared.pathsOlderThan(cutoffMs: cutoff)) ?? []
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
                    let format = SettingsStore.StorageFormat(rawValue: s.storageFormatRaw) ?? .heic
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
                } catch {
                }
            }
        }
    }
}
