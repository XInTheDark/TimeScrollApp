import Foundation

/// How Time Warp reads each supported browser. Measured on macOS 27.2 (docs/time-warp.md): Chromium
/// browsers report the active tab's address as the window's `AXDocument`; Safari and Firefox only
/// report it on the page's web area. Private-window detection comes from `PrivateBrowsingCatalog`.
struct TimeWarpBrowser: Sendable {
  enum Family: Sendable {
    case chromium
    case safari
    case firefox
  }

  let family: Family
  /// What the browser appends to window titles, such as " - Google Chrome".
  let titleSuffixNames: [String]

  /// Whether the address comes from the window's document rather than a walk to the web area.
  var readsDocumentAttribute: Bool { family == .chromium }

  /// Whether its tabs can be listed over Apple Events.
  var listsTabsOverAppleEvents: Bool { family != .firefox }
}

enum TimeWarpBrowserCatalog {
  static let browsers: [String: TimeWarpBrowser] = {
    var table: [String: TimeWarpBrowser] = [:]
    func add(_ ids: [String], _ family: TimeWarpBrowser.Family, _ names: [String]) {
      for id in ids { table[id] = TimeWarpBrowser(family: family, titleSuffixNames: names) }
    }
    add(["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"],
        .chromium, ["Google Chrome"])
    add(["org.chromium.Chromium"], .chromium, ["Chromium"])
    add(["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"], .chromium, ["Brave"])
    add(["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"],
        .chromium, ["Microsoft Edge"])
    add(["company.thebrowser.Browser"], .chromium, ["Arc"])
    add(["com.vivaldi.Vivaldi"], .chromium, ["Vivaldi"])
    add(["com.operasoftware.Opera"], .chromium, ["Opera"])
    add(["com.apple.Safari", "com.apple.SafariTechnologyPreview"], .safari, [])
    add(["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
        .firefox, ["Mozilla Firefox", "Firefox Developer Edition", "Firefox Nightly"])
    add(["app.zen-browser.zen"], .firefox, ["Zen Browser", "Zen"])
    return table
  }()

  static func browser(forBundleId bundleId: String) -> TimeWarpBrowser? {
    browsers[bundleId]
  }

  /// Terminal.app reports its window's current folder as the document.
  static let terminalBundleId = "com.apple.Terminal"
  static let iTermBundleId = "com.googlecode.iterm2"
  static let finderBundleId = "com.apple.finder"
}
