import SwiftUI
import Foundation

struct StatsView: View {
    @State private var snapshotCount: Int = 0
    @State private var storageBytes: Int64 = 0
    @State private var snapshotsBytes: Int64 = 0
    @State private var dbBytes: Int64 = 0
    @State private var avgBytes: Int64 = 0
    @State private var usageSeconds: TimeInterval = 0
    @State private var selectedWindowIndex: Int = 0

    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    private let windows: [(label: String, seconds: TimeInterval?)] = [
        ("All time", nil),
        ("1h", 3600),
        ("6h", 3*3600),
        ("24h", 24*3600),
        ("7d", 7*24*3600),
        ("30d", 30*24*3600),
        ("90d", 90*24*3600),
        ("1y", 365*24*3600),
    ]

    var body: some View {
        HStack { // Center horizontally
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                // Window selector
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
//                        Text("Window:")
                        Slider(value: Binding(get: { Double(selectedWindowIndex) }, set: { newVal in
                            let idx = Int(newVal.rounded())
                            selectedWindowIndex = max(0, min(windows.count-1, idx))
                            recompute()
                        }), in: 0...Double(windows.count - 1), step: 1)
                        .frame(maxWidth: 260)
                        Text(windows[selectedWindowIndex].label)
                            .font(.headline)
                            .frame(width: 44, alignment: .leading)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Snapshots:")
                        Text("\(snapshotCount)").bold()
                    }
                    HStack {
                        Text("Storage:")
                        Text(byteString(storageBytes)).bold()
                    }
                    HStack {
                        Text("  - Snapshots:")
                        Text(byteString(snapshotsBytes)).bold()
                    }.font(.footnote)
                    HStack {
                        Text("  - Database:")
                        Text(byteString(dbBytes)).bold()
                    }.font(.footnote)
                    HStack {
                        Text("  - Avg snapshot:")
                        Text(byteString(avgBytes)).bold()
                    }.font(.footnote)
                    HStack {
                        Text("Usage:")
                        Text(timeString(usageSeconds)).bold()
                    }
                }
                HStack {
                    Spacer()
                    Button("Refresh") { recompute(fullDisk: true) }
                        .keyboardShortcut(.init("r"), modifiers: [.command])
                }
            }
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .onAppear { recompute(fullDisk: true) }
        .onReceive(timer) { _ in recomputeDynamic() }
    }

    private func recompute(fullDisk: Bool = false) {
        let window = windows[selectedWindowIndex]
        let now = Date().timeIntervalSince1970
        let nowMs = Int64(now * 1000)
        var cutoffMs: Int64? = nil
        if let secs = window.seconds { cutoffMs = nowMs - Int64(secs * 1000) }

        if let c = cutoffMs {
            snapshotCount = (try? DB.shared.snapshotCountSince(ms: c)) ?? 0
            snapshotsBytes = (try? DB.shared.sumSnapshotBytesSince(ms: c)) ?? 0
            avgBytes = (try? DB.shared.avgSnapshotBytesSince(ms: c)) ?? 0
            usageSeconds = (try? DB.shared.usageSecondsSince(cutoff: now - (window.seconds ?? 0), now: now)) ?? 0
        } else {
            snapshotCount = (try? DB.shared.snapshotCount()) ?? 0
            snapshotsBytes = (try? DB.shared.sumSnapshotBytesAll()) ?? 0
            avgBytes = (try? DB.shared.avgSnapshotBytesAll()) ?? 0
            usageSeconds = (try? DB.shared.totalUsageSeconds(now: now)) ?? 0
        }
        if fullDisk {
            dbBytes = computeDBSize() // Always full DB size
            // Refresh snapshot directory size only when fullDisk is requested (expensive); we reuse snapshotsBytes
        }
        storageBytes = snapshotsBytes + dbBytes
    }

    // For timer updates: only usage needs frequent refresh (and any open session count unaffected).
    private func recomputeDynamic() {
        let window = windows[selectedWindowIndex]
        let now = Date().timeIntervalSince1970
        if let secs = window.seconds {
            usageSeconds = (try? DB.shared.usageSecondsSince(cutoff: now - secs, now: now)) ?? usageSeconds
        } else {
            usageSeconds = (try? DB.shared.totalUsageSeconds(now: now)) ?? usageSeconds
        }
    }

    private func computeDBSize() -> Int64 {
        // Use existing dbURL if available, else construct expected path
        var urls: [URL] = []
        if let u = DB.shared.dbURL { urls.append(u) }
        else { urls.append(StoragePaths.dbURL()) }
        if let base = urls.first?.deletingPathExtension() {
            // Also include WAL/SHM if present
            urls.append(base.appendingPathExtension("sqlite-wal"))
            urls.append(base.appendingPathExtension("sqlite-shm"))
        }
        var total: Int64 = 0
        StoragePaths.withSecurityScope {
            for u in urls {
                if let vals = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
                    total += Int64(vals.fileSize ?? 0)
                }
            }
        }
        return total
    }

    private func byteString(_ n: Int64) -> String {
        let units = ["B","KB","MB","GB","TB"]
        var size = Double(n)
        var idx = 0
        while size > 1024 && idx < units.count-1 { size /= 1024; idx += 1 }
        return String(format: "%.2f %@", size, units[idx])
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "0s" }
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let remS = s % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        if m > 0 { return String(format: "%dm %ds", m, remS) }
        return "\(remS)s"
    }
}
