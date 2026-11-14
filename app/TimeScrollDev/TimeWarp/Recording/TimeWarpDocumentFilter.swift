import AppKit
import Foundation

/// Turns an app's reported document (`AXDocument`) into a file or folder worth recording.
/// Electron apps report empty strings or pages inside their own bundle, and some apps report web
/// addresses for internal pages; only real local files outside applications and the system count.
enum TimeWarpDocumentFilter {
  static let ignoredPathPrefixes = ["/System/", "/Library/Apple/", "/usr/", "/bin/", "/sbin/", "/private/var/db/"]

  /// The file path, or nil if the value is not a local file worth keeping.
  static func path(fromDocument value: String) -> String? {
    guard !value.isEmpty, let url = URL(string: value), url.isFileURL else { return nil }
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/"), path.count > 1 else { return nil }
    guard !ignoredPathPrefixes.contains(where: { path.hasPrefix($0) }) else { return nil }
    // Pages and resources inside an application bundle belong to the app, not to the user.
    guard !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
    return path
  }

  /// A recorded path is a folder or a document. Checked once when recorded; one `stat`.
  static func kind(forPath path: String, isDirectory: (String) -> Bool? = TimeWarpDocumentFilter.liveIsDirectory) -> TimeWarpItemKind? {
    guard let directory = isDirectory(path) else { return nil }
    return directory ? .folder : .document
  }

  static func liveIsDirectory(_ path: String) -> Bool? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    // A package (such as a Pages or Keynote file) is a document even though it is a folder.
    if isDirectory.boolValue, NSWorkspace.shared.isFilePackage(atPath: path) { return false }
    return isDirectory.boolValue
  }
}
