import Foundation
import SwiftUI
import CoreGraphics

final class IngestQueue {
    static let shared = IngestQueue()
    private init() { ensureDir() }

    struct Record: Codable {
        let snapshotPath: String
        let startedAtMs: Int64
        let appBundleId: String?
        let appName: String?
        let bytes: Int64
        let width: Int
        let height: Int
        let format: String
        let hash64: Int64
        let ocrText: String
        let ocrBoxes: [OCRLine]
        let thumbPath: String?
    }

    private var ingestTimer: Timer?
    private let fm = FileManager.default
    private var dir: URL { StoragePaths.ingestQueueDir() }

    private func ensureDir() {
        StoragePaths.withSecurityScope {
            if !fm.fileExists(atPath: dir.path) { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        }
    }

    func enqueue(path: URL,
                 startedAtMs: Int64,
                 appBundleId: String?,
                 appName: String?,
                 bytes: Int64,
                 width: Int,
                 height: Int,
                 format: String,
                 hash64: Int64,
                 ocrText: String,
                 ocrBoxes: [OCRLine],
                 thumbPath: String?) throws {
        ensureDir()
        let rec = Record(snapshotPath: path.path, startedAtMs: startedAtMs, appBundleId: appBundleId, appName: appName, bytes: bytes, width: width, height: height, format: format, hash64: hash64, ocrText: ocrText, ocrBoxes: ocrBoxes, thumbPath: thumbPath)
        let clear = try JSONEncoder().encode(rec)
        let data = try FileCrypter.shared.encryptData(clear, timestampMs: startedAtMs)
        StoragePaths.withSecurityScope {
            let nonce = UUID().uuidString.prefix(8)
            let name = Self.tsFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(startedAtMs)/1000)) + "-\(nonce).iq1"
            let url = dir.appendingPathComponent(name)
            let tmp = url.appendingPathExtension("tmp")
            try? data.write(to: tmp, options: Data.WritingOptions.atomic)
            let _ = try? fm.replaceItemAt(url, withItemAt: tmp)
            // Update queued count to reflect actual number of records present
            let d = UserDefaults.standard
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                let count = files.filter { $0.pathExtension == "iq1" }.count
                d.set(count, forKey: "vault.queuedCount")
            }
        }
    }

    func startIngestIfNeeded() {
        guard ingestTimer == nil else { return }
        ingestTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.drainOnce()
        }
        ingestTimer?.tolerance = 0.5
    }

    func stop() {
        ingestTimer?.invalidate(); ingestTimer = nil
    }

    private func drainOnce() {
        // Snapshot main-actor state via UserDefaults to avoid crossing actors
        let d = UserDefaults.standard
        let unlocked = d.bool(forKey: "vault.isUnlocked")
        guard unlocked else { return }
        let files = StoragePaths.withSecurityScope { (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? [] }
        let recs = files.filter { $0.pathExtension == "iq1" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !recs.isEmpty else { d.set(0, forKey: "vault.queuedCount"); return }
        var processed = 0
        for u in recs.prefix(200) {
            do {
                let blob = try StoragePaths.withSecurityScope { try Data(contentsOf: u) }
                let data = try FileCrypter.shared.decryptData(blob)
                let rec = try JSONDecoder().decode(Record.self, from: data)
                let rowId = try DB.shared.insertSnapshot(
                    startedAtMs: rec.startedAtMs,
                    path: rec.snapshotPath,
                    text: rec.ocrText,
                    appBundleId: rec.appBundleId,
                    appName: rec.appName,
                    boxes: rec.ocrBoxes,
                    bytes: rec.bytes,
                    width: rec.width,
                    height: rec.height,
                    format: rec.format,
                    hash64: rec.hash64,
                    thumbPath: rec.thumbPath
                )
                if rowId > 0 {
                    // Notify UI that a snapshot row was inserted while previously locked
                    Task { @MainActor in AppState.shared.lastSnapshotTick &+= 1 }
                    try? StoragePaths.withSecurityScope { try fm.removeItem(at: u) }
                    processed += 1
                }
            } catch {
                // Move to failed/
                let failedDir = dir.appendingPathComponent("failed", isDirectory: true)
                StoragePaths.withSecurityScope {
                    if !fm.fileExists(atPath: failedDir.path) { try? fm.createDirectory(at: failedDir, withIntermediateDirectories: true) }
                    let dest = failedDir.appendingPathComponent(u.lastPathComponent)
                    _ = try? fm.moveItem(at: u, to: dest)
                }
            }
        }
        // Update queued count metric
        let remaining = StoragePaths.withSecurityScope { ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "iq1" }.count }
        d.set(remaining, forKey: "vault.queuedCount")
    }

    private static let tsFormatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        return df
    }()
}
