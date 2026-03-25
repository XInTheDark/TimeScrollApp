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
  @State private var statsRefreshToken: Int = 0
  @State private var usageRefreshToken: Int = 0
  @State private var isVisible: Bool = false

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
    HStack {
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 12) {
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
    .onAppear {
      isVisible = true
      recompute(fullDisk: true)
    }
    .onDisappear {
      isVisible = false
    }
    .onReceive(timer) { _ in
      guard isVisible else { return }
      recomputeDynamic()
    }
  }

  private func recompute(fullDisk: Bool = false) {
    statsRefreshToken &+= 1
    let token = statsRefreshToken
    let windowIndex = selectedWindowIndex
    let window = windows[windowIndex]
    let currentDBBytes = dbBytes

    DispatchQueue.global(qos: .userInitiated).async {
      let stats = Self.computeStats(for: window, includeDiskUsage: fullDisk, fallbackDBBytes: currentDBBytes)
      DispatchQueue.main.async {
        guard token == statsRefreshToken, selectedWindowIndex == windowIndex else { return }
        snapshotCount = stats.snapshotCount
        storageBytes = stats.storageBytes
        snapshotsBytes = stats.snapshotsBytes
        dbBytes = stats.dbBytes
        avgBytes = stats.avgBytes
        usageSeconds = stats.usageSeconds
      }
    }
  }

  private func recomputeDynamic() {
    usageRefreshToken &+= 1
    let token = usageRefreshToken
    let windowIndex = selectedWindowIndex
    let window = windows[windowIndex]

    DispatchQueue.global(qos: .utility).async {
      let updatedUsage = Self.computeUsageSeconds(for: window, now: Date().timeIntervalSince1970)
      DispatchQueue.main.async {
        guard token == usageRefreshToken, selectedWindowIndex == windowIndex else { return }
        usageSeconds = updatedUsage
      }
    }
  }

  private static func computeStats(
    for window: (label: String, seconds: TimeInterval?),
    includeDiskUsage: Bool,
    fallbackDBBytes: Int64
  ) -> StatsSnapshot {
    let now = Date().timeIntervalSince1970
    let nowMs = Int64(now * 1000)
    let cutoffMs = window.seconds.map { nowMs - Int64($0 * 1000) }

    let snapshotCount: Int
    let snapshotsBytes: Int64
    let usageSeconds: TimeInterval

    if let cutoffMs {
      snapshotCount = (try? DB.shared.snapshotCountSince(ms: cutoffMs)) ?? 0
      snapshotsBytes = (try? DB.shared.sumSnapshotBytesSince(ms: cutoffMs)) ?? 0
      usageSeconds = (try? DB.shared.usageSecondsSince(cutoff: now - (window.seconds ?? 0), now: now)) ?? 0
    } else {
      snapshotCount = (try? DB.shared.snapshotCount()) ?? 0
      snapshotsBytes = (try? DB.shared.sumSnapshotBytesAll()) ?? 0
      usageSeconds = (try? DB.shared.totalUsageSeconds(now: now)) ?? 0
    }

    let resolvedDBBytes = includeDiskUsage ? computeDBSize() : fallbackDBBytes
    let storageBytes = snapshotsBytes + resolvedDBBytes
    let avgBytes = snapshotCount > 0 ? storageBytes / Int64(snapshotCount) : 0

    return StatsSnapshot(
      snapshotCount: snapshotCount,
      storageBytes: storageBytes,
      snapshotsBytes: snapshotsBytes,
      dbBytes: resolvedDBBytes,
      avgBytes: avgBytes,
      usageSeconds: usageSeconds
    )
  }

  private static func computeUsageSeconds(for window: (label: String, seconds: TimeInterval?), now: TimeInterval) -> TimeInterval {
    if let secs = window.seconds {
      return (try? DB.shared.usageSecondsSince(cutoff: now - secs, now: now)) ?? 0
    }
    return (try? DB.shared.totalUsageSeconds(now: now)) ?? 0
  }

  private static func computeDBSize() -> Int64 {
    let dbURL = StoragePaths.dbURL()
    let base = dbURL.deletingPathExtension()
    let urls = [
      dbURL,
      base.appendingPathExtension("sqlite-wal"),
      base.appendingPathExtension("sqlite-shm")
    ]

    var total: Int64 = 0
    StoragePaths.withSecurityScope {
      for url in urls {
        if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
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

private struct StatsSnapshot {
  let snapshotCount: Int
  let storageBytes: Int64
  let snapshotsBytes: Int64
  let dbBytes: Int64
  let avgBytes: Int64
  let usageSeconds: TimeInterval
}
