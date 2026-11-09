import Foundation

/// How one browser marks its private windows.
struct PrivateBrowsingProfile: Sendable {
  enum Verification: Sendable {
    /// Confirmed on a real private window through Accessibility.
    case liveTested
    /// Expected from the browser's engine or naming, but not yet confirmed on a real window.
    case unverified
  }

  struct AddressFieldRule: Sendable {
    let identifier: String
    let descriptions: [String]
  }

  let name: String
  let bundleIds: Set<String>
  let verification: Verification
  var titleAffixes: [PrivateBrowsingMarkers.TitleAffix] = []
  var titleSubstrings: [String] = []
  var addressField: AddressFieldRule?
}

/// Every browser TimeScroll knows how to check. Adding one here is all detection needs.
enum PrivateBrowsingCatalog {
  private static let chromiumAffixes = PrivateBrowsingMarkers.chromeTitleAffixes + PrivateBrowsingMarkers.braveTitleAffixes

  static let profiles: [PrivateBrowsingProfile] = [
    PrivateBrowsingProfile(
      name: "Chrome",
      bundleIds: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
                  "com.google.Chrome.canary", "org.chromium.Chromium"],
      verification: .liveTested,
      titleAffixes: PrivateBrowsingMarkers.chromeTitleAffixes),
    PrivateBrowsingProfile(
      name: "Brave",
      bundleIds: ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"],
      verification: .liveTested,
      titleAffixes: PrivateBrowsingMarkers.braveTitleAffixes),
    PrivateBrowsingProfile(
      name: "Firefox",
      bundleIds: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
      verification: .liveTested,
      titleAffixes: PrivateBrowsingMarkers.firefoxTitleAffixes),
    PrivateBrowsingProfile(
      name: "Zen",
      bundleIds: ["app.zen-browser.zen"],
      verification: .liveTested,
      titleAffixes: PrivateBrowsingMarkers.firefoxTitleAffixes),
    PrivateBrowsingProfile(
      name: "Safari",
      bundleIds: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"],
      verification: .liveTested,
      titleAffixes: PrivateBrowsingMarkers.safariTitleAffixes,
      addressField: .init(identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
                          descriptions: PrivateBrowsingMarkers.safariAddressFieldDescriptions)),
    PrivateBrowsingProfile(
      name: "Edge",
      bundleIds: ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
                  "com.microsoft.edgemac.Canary"],
      verification: .unverified,
      titleAffixes: chromiumAffixes,
      titleSubstrings: ["InPrivate"]),
    PrivateBrowsingProfile(
      name: "Arc",
      bundleIds: ["company.thebrowser.Browser"],
      verification: .unverified,
      titleAffixes: chromiumAffixes),
    PrivateBrowsingProfile(
      name: "Vivaldi",
      bundleIds: ["com.vivaldi.Vivaldi"],
      verification: .unverified,
      titleAffixes: chromiumAffixes),
    PrivateBrowsingProfile(
      name: "Opera",
      bundleIds: ["com.operasoftware.Opera"],
      verification: .unverified,
      titleAffixes: chromiumAffixes),
  ]

  private static let byBundleId: [String: PrivateBrowsingProfile] = {
    var table: [String: PrivateBrowsingProfile] = [:]
    for profile in profiles {
      for bundleId in profile.bundleIds { table[bundleId] = profile }
    }
    return table
  }()

  static func profile(forBundleId bundleId: String) -> PrivateBrowsingProfile? {
    byBundleId[bundleId]
  }
}
