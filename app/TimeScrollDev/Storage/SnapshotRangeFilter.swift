import Foundation

/// The snapshots in `[fromMs, toMs)` that an action applies to. Filters left empty match everything.
struct SnapshotRangeFilter: Equatable, Sendable {
  var fromMs: Int64
  var toMs: Int64
  var appBundleIds: [String] = []
  var captureKinds: [CaptureKind] = []
  var audioSourceKinds: [AudioSourceKind] = []

  var isFiltered: Bool {
    !appBundleIds.isEmpty || !captureKinds.isEmpty || !audioSourceKinds.isEmpty
  }

  /// A `WHERE` condition on `ts_snapshot`, with values quoted because the batch statements run
  /// through `sqlite3_exec`.
  var whereSQL: String {
    var parts = ["started_at_ms >= \(fromMs)", "started_at_ms < \(toMs)"]
    if !appBundleIds.isEmpty { parts.append("app_bundle_id IN (\(Self.quoted(appBundleIds)))") }
    if !captureKinds.isEmpty { parts.append("capture_kind IN (\(Self.quoted(captureKinds.map(\.rawValue))))") }
    if !audioSourceKinds.isEmpty { parts.append("source_kind IN (\(Self.quoted(audioSourceKinds.map(\.rawValue))))") }
    return parts.joined(separator: " AND ")
  }

  private static func quoted(_ values: [String]) -> String {
    values.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
  }
}
