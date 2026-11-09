import Testing
@testable import TimeScroll

struct PrivateWindowClassifierTests {
  private func profile(_ bundleId: String) throws -> PrivateBrowsingProfile {
    try #require(PrivateBrowsingCatalog.profile(forBundleId: bundleId))
  }

  private func evidence(_ title: String?, description: String? = nil) -> PrivateWindowEvidence {
    PrivateWindowEvidence(title: title, subrole: "AXStandardWindow", hasCloseButton: true, addressFieldDescription: description)
  }

  // Titles measured on real private windows.
  @Test(arguments: [
    ("com.google.Chrome", "Example Domain - Google Chrome (Incognito)"),
    ("com.google.Chrome", "New Incognito Tab - Google Chrome (Incognito)"),
    ("com.brave.Browser", "New Private Tab - Brave (Private)"),
    ("app.zen-browser.zen", "Example Domain — Private Browsing"),
    ("org.mozilla.firefox", "Mozilla Firefox — Private Browsing"),
    ("com.apple.Safari", "Start Page, Private Browsing"),
  ])
  func measuredPrivateTitlesArePrivate(bundleId: String, title: String) throws {
    #expect(PrivateWindowClassifier.verdict(for: evidence(title), profile: try profile(bundleId)) == .privateWindow)
  }

  @Test(arguments: [
    ("com.google.Chrome", "Example Domain - Google Chrome"),
    ("com.brave.Browser", "Example Domain - Brave"),
    ("org.mozilla.firefox", "Example Domain — Mozilla Firefox"),
    ("com.apple.Safari", "Start Page"),
    // A word in the middle of a page title is not the marker.
    ("com.google.Chrome", "What (Incognito) means - Google Chrome"),
    ("com.apple.Safari", "Private Browsing tips"),
  ])
  func normalTitlesAreNormal(bundleId: String, title: String) throws {
    #expect(PrivateWindowClassifier.verdict(for: evidence(title), profile: try profile(bundleId)) == .normal)
  }

  // Translations come from the browsers' own resources.
  @Test(arguments: [
    ("com.google.Chrome", "Beispiel - Google Chrome (anonym)"),
    ("com.google.Chrome", "例 - Google Chrome（シークレット モード）"),
    ("com.google.Chrome", "Exemple - Google Chrome (Navigation privée)"),
    ("com.google.Chrome", "مثال - Google Chrome (التصفح المتخفي)"),
    ("com.brave.Browser", "Beispiel - Brave (Privat)"),
    ("org.mozilla.firefox", "Beispiel — Privater Modus"),
    ("org.mozilla.firefox", "例 — プライベートブラウジング"),
    ("com.apple.Safari", "Startsida, privat surfning"),
  ])
  func translatedTitlesArePrivate(bundleId: String, title: String) throws {
    #expect(PrivateWindowClassifier.verdict(for: evidence(title), profile: try profile(bundleId)) == .privateWindow)
  }

  @Test func directionalMarksDoNotHideTheMarker() throws {
    let title = "مثال - Google Chrome (التصفح المتخفي)\u{200F}"
    #expect(PrivateWindowClassifier.verdict(for: evidence(title), profile: try profile("com.google.Chrome")) == .privateWindow)
  }

  @Test func safariAddressFieldCoversAnUnrecognisedTitle() throws {
    let safari = try profile("com.apple.Safari")
    #expect(PrivateWindowClassifier.verdict(for: evidence("Page", description: "smart search field in a private window"), profile: safari) == .privateWindow)
    #expect(PrivateWindowClassifier.verdict(for: evidence("Page", description: "smart search field"), profile: safari) == .normal)
  }

  @Test func addressFieldIsIgnoredForBrowsersWithoutARule() throws {
    let chrome = try profile("com.google.Chrome")
    #expect(PrivateWindowClassifier.verdict(for: evidence("Page", description: "in a private window"), profile: chrome) == .normal)
  }

  @Test func bubblesAndHelperWindowsAreAuxiliary() throws {
    let brave = try profile("com.brave.Browser")
    let bubble = PrivateWindowEvidence(title: "Translate this page?", subrole: "AXStandardWindow", hasCloseButton: false)
    #expect(PrivateWindowClassifier.verdict(for: bubble, profile: brave) == .auxiliary)
    let dialog = PrivateWindowEvidence(title: "Save password?", subrole: "AXDialog", hasCloseButton: true)
    #expect(PrivateWindowClassifier.verdict(for: dialog, profile: brave) == .auxiliary)
    let helper = PrivateWindowEvidence(title: "", subrole: nil, hasCloseButton: false)
    #expect(PrivateWindowClassifier.verdict(for: helper, profile: try profile("org.mozilla.firefox")) == .auxiliary)
  }

  @Test func untitledStandardWindowIsUndecided() throws {
    let firefox = try profile("org.mozilla.firefox")
    #expect(PrivateWindowClassifier.verdict(for: evidence(""), profile: firefox) == .undetermined)
    #expect(PrivateWindowClassifier.verdict(for: evidence(nil), profile: firefox) == .undetermined)
  }

  @Test func catalogHasNoEmptyMarkersOrDuplicateBundleIds() {
    var seen = Set<String>()
    for profile in PrivateBrowsingCatalog.profiles {
      #expect(!profile.titleAffixes.isEmpty)
      // An empty affix would mark every window as private.
      #expect(profile.titleAffixes.allSatisfy { !$0.prefix.isEmpty || !$0.suffix.isEmpty })
      for bundleId in profile.bundleIds {
        #expect(seen.insert(bundleId).inserted)
      }
    }
  }

  @Test func windowIdentityFunctionIsAvailable() {
    #expect(LivePrivateWindowEvidenceReader.canIdentifyWindows)
  }

  @Test func unknownAppsHaveNoProfile() {
    #expect(PrivateBrowsingCatalog.profile(forBundleId: "com.apple.Notes") == nil)
  }
}
