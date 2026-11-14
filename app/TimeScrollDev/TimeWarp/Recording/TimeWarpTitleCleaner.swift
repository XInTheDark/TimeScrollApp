import Foundation

/// Removes browser chrome from window titles: " - Google Chrome", the profile name after it,
/// tab-group notes and the address Chrome appends for grouped tabs.
enum TimeWarpTitleCleaner {
  static let maxLength = 300

  static func pageTitle(_ raw: String?, browser: TimeWarpBrowser?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    // A leading space so a title that is only " - Google Chrome" still matches its separator.
    var title = " " + trimmed
    for name in browser?.titleSuffixNames ?? [] {
      for separator in [" - ", " — ", " – "] {
        if let range = title.range(of: separator + name, options: .backwards) {
          title = String(title[..<range.lowerBound])
        }
      }
    }
    if let range = title.range(of: " - Part of group ") { title = String(title[..<range.lowerBound]) }
    if let range = title.range(of: " · http", options: .backwards) { title = String(title[..<range.lowerBound]) }
    return clipped(title)
  }

  /// A file's title is its name: window titles add page counts and project names that change.
  static func fileTitle(path: String) -> String {
    (path as NSString).lastPathComponent
  }

  private static func clipped(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) + "…" : trimmed
  }
}
