import AppKit

/// Icons for Time Warp rows, from the system's caches.
@MainActor
enum TimeWarpIcons {
  static func icon(for item: TimeWarpPlanItem) -> NSImage {
    let workspace = NSWorkspace.shared
    switch item.kind {
    case .page:
      if let app = item.appBundleId.flatMap(workspace.urlForApplication(withBundleIdentifier:)) {
        return workspace.icon(forFile: app.path)
      }
      return symbol("globe")
    case .document, .folder:
      if FileManager.default.fileExists(atPath: item.value) { return workspace.icon(forFile: item.value) }
      return symbol(item.kind == .folder ? "folder" : "doc")
    case .app:
      if let app = workspace.urlForApplication(withBundleIdentifier: item.value) { return workspace.icon(forFile: app.path) }
      return symbol("app")
    case .warpPoint:
      return symbol("mappin")
    }
  }

  static func appName(_ bundleId: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }

  private static func symbol(_ name: String) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
  }
}
