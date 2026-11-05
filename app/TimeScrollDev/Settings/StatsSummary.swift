import Foundation

/// The numbers shown on the Stats pane for one time range.
struct StatsSummary: Equatable, Sendable {
  var snapshotCount: Int = 0
  var snapshotBytes: Int64 = 0
  /// Size of the whole database. Rows are not attributable to a time range, so it is only
  /// meaningful, and only counted towards storage, for all time.
  var databaseBytes: Int64?
  var usageSeconds: TimeInterval = 0

  var storageBytes: Int64 { snapshotBytes + (databaseBytes ?? 0) }
  var averageSnapshotBytes: Int64 { snapshotCount > 0 ? snapshotBytes / Int64(snapshotCount) : 0 }

  static func byteString(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = Double(bytes)
    var index = 0
    while size >= 1024 && index < units.count - 1 {
      size /= 1024
      index += 1
    }
    return String(format: "%.2f %@", size, units[index])
  }

  static func durationString(_ seconds: TimeInterval) -> String {
    if seconds <= 0 { return "0s" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(total % 60)s" }
    return "\(total)s"
  }
}
