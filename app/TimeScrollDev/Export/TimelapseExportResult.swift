import Foundation

struct TimelapseExportResult: Sendable {
  var previews = 0
  var skipped = 0

  var message: String {
    var parts = ["Export complete."]
    if previews > 0 { parts.append("\(previews) \(previews == 1 ? "snapshot used a saved preview." : "snapshots used saved previews.")") }
    if skipped > 0 { parts.append("\(skipped) unavailable \(skipped == 1 ? "snapshot was skipped." : "snapshots were skipped.")") }
    return parts.joined(separator: " ")
  }
}
