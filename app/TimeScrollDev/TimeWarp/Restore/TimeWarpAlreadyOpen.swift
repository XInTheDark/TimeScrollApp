import AppKit
import Foundation

/// Finds which chosen items are already open, so a Time Warp doesn't open them twice. Pages count
/// when a browser has a tab at the same address, files and folders when a window shows them, apps
/// when they run. Uses the recorder's reader, so private windows and excluded apps are never read.
enum TimeWarpAlreadyOpen {
  /// What is open right now.
  struct OpenNow: Equatable, Sendable {
    var pages: Set<String> = []
    var paths: Set<String> = []
    var apps: Set<String> = []
  }

  /// Ids of `items` that are already open. Pure.
  static func ids(of items: [TimeWarpPlanItem], openNow: OpenNow) -> Set<String> {
    Set(items.filter { item in
      switch item.kind {
      case .page: return openNow.pages.contains(item.value)
      case .document, .folder: return openNow.paths.contains(standardized(item.value))
      case .app: return openNow.apps.contains(item.value)
      case .warpPoint: return false
      }
    }.map(\.id))
  }

  /// Reads the running apps that could have `items` open. Blocks on Accessibility and Apple Events
  /// (never prompting); call off the main thread.
  static func read(for items: [TimeWarpPlanItem]) -> OpenNow {
    let excluded = TimeWarpSettings.excludedBundleIds()
    var bundleIds = Set(items.compactMap(\.appBundleId))
    if items.contains(where: { $0.kind == .page }) { bundleIds.formUnion(TimeWarpBrowserCatalog.browsers.keys) }
    if items.contains(where: { $0.kind == .folder }) { bundleIds.insert(TimeWarpBrowserCatalog.finderBundleId) }

    var openNow = OpenNow()
    let reader = TimeWarpOpenItemsReader()
    for app in NSWorkspace.shared.runningApplications {
      guard let bundleId = app.bundleIdentifier else { continue }
      openNow.apps.insert(bundleId)
      guard bundleIds.contains(bundleId), !excluded.contains(bundleId) else { continue }
      let allowed = TimeWarpAppleEvents.permission(bundleId: bundleId, askUser: false) == .allowed
      for item in reader.read(pid: app.processIdentifier, bundleId: bundleId, excluded: excluded, appleEventsAllowed: allowed) ?? [] {
        switch item.kind {
        case .page: openNow.pages.insert(item.value)
        case .document, .folder: openNow.paths.insert(standardized(item.value))
        default: break
        }
      }
    }
    return openNow
  }

  private static func standardized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
