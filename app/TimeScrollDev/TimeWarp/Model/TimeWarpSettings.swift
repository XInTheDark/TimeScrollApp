import Foundation

/// Time Warp preference keys and background-safe reads (never through `SettingsStore`).
enum TimeWarpSettings {
  static let enabledKey = "settings.timeWarpEnabled"
  static let recordsOpenItemsKey = "settings.timeWarpRecordOpenItems"
  static let warpPointShortcutKey = "settings.timeWarpWarpPointShortcut"
  static let excludedAppsKey = "settings.blacklistBundleIds"

  /// On unless the user turned it off.
  static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
  }

  static func recordsOpenItems(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: recordsOpenItemsKey)
  }

  static func warpPointShortcutEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: warpPointShortcutKey) == nil ? true : defaults.bool(forKey: warpPointShortcutKey)
  }

  static func excludedBundleIds(_ defaults: UserDefaults = .standard) -> Set<String> {
    Set(defaults.array(forKey: excludedAppsKey) as? [String] ?? [])
  }

  /// Posted on the main thread when a Time Warp setting changes, so recording can start or stop.
  static let didChangeNotification = Notification.Name("TimeWarpSettingsDidChange")

  /// Posted on the main thread after a Warp point is stored, so the timeline can show it.
  static let warpPointAddedNotification = Notification.Name("TimeWarpPointAdded")

  /// Whether the timeline shows Warp point markers (View menu).
  static let showsWarpPointsKey = "ui.timeline.showWarpPoints"
}
