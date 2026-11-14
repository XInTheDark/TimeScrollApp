import ApplicationServices
import Foundation

/// Reads everything an app has open: every tab of a browser (Apple Events), the active tab of each
/// browser window (Accessibility, when Apple Events are not allowed), every Finder folder, or every
/// document window. Private and unclassified windows are left out. Returns nil when the app could
/// not be read, so its recorded open items stay as they were.
final class TimeWarpOpenItemsReader {
  static let maxItemsPerApp = 500

  private let appleEvents = TimeWarpAppleEvents()
  private let classifier = TimeWarpWindowClassifier()

  func read(pid: pid_t, bundleId: String, excluded: Set<String>, appleEventsAllowed: Bool) -> Set<TimeWarpItem>? {
    guard !excluded.contains(bundleId) else { return [] }
    let browser = TimeWarpBrowserCatalog.browser(forBundleId: bundleId)
    let profile = PrivateBrowsingCatalog.profile(forBundleId: bundleId)
    if browser != nil || profile != nil {
      // Browsers whose private windows cannot be told apart are never read.
      guard let browser, let profile, profile.verification == .liveTested else { return [] }
      if appleEventsAllowed, browser.listsTabsOverAppleEvents,
         let tabs = tabs(pid: pid, bundleId: bundleId, browser: browser, profile: profile) {
        return capped(tabs)
      }
      return capped(windowPages(pid: pid, browser: browser, profile: profile))
    }
    if bundleId == TimeWarpBrowserCatalog.finderBundleId {
      return appleEventsAllowed ? finderFolders() : nil
    }
    return capped(documents(pid: pid))
  }

  /// iTerm2's current folder: the tty of the front session, then the folder of its foreground process.
  func iTermFolder(pid: pid_t) -> String? {
    let result = appleEvents.run(bundleId: TimeWarpBrowserCatalog.iTermBundleId,
                                 body: "return tty of current session of current window")
    guard let tty = result?.stringValue, tty.hasPrefix("/dev/") else { return nil }
    return TimeWarpTerminalFolder.foregroundDirectory(ttyPath: tty)
  }

  func forgetWindows() {
    classifier.forgetAll()
  }

  // MARK: Browsers

  private func tabs(pid: pid_t, bundleId: String, browser: TimeWarpBrowser, profile: PrivateBrowsingProfile) -> Set<TimeWarpItem>? {
    switch browser.family {
    case .chromium:
      // Chromium reports each window's mode, so incognito windows are skipped at the source.
      let body = """
      set out to {}
      repeat with w in windows
        try
          if mode of w is "normal" then set end of out to {URL of tabs of w, title of tabs of w}
        end try
      end repeat
      return out
      """
      guard let result = appleEvents.run(bundleId: bundleId, body: body) else { return nil }
      return Set(TimeWarpAppleEvents.list(result).flatMap { window in
        pages(urls: TimeWarpAppleEvents.strings(window.atIndex(1)), titles: TimeWarpAppleEvents.strings(window.atIndex(2)), browser: browser)
      })
    case .safari:
      // Safari's Apple Events do not say which windows are private. A window is kept only when its
      // name matches a window Accessibility classified as normal and no private one.
      let body = """
      set out to {}
      repeat with w in windows
        try
          set end of out to {name of w, URL of tabs of w, name of tabs of w}
        end try
      end repeat
      return out
      """
      guard let result = appleEvents.run(bundleId: bundleId, body: body) else { return nil }
      let titles = classifiedTitles(pid: pid, profile: profile)
      return Set(TimeWarpAppleEvents.list(result).flatMap { window -> [TimeWarpItem] in
        guard let name = window.atIndex(1)?.stringValue,
              titles.normal.contains(name), !titles.other.contains(name) else { return [] }
        return pages(urls: TimeWarpAppleEvents.strings(window.atIndex(2)), titles: TimeWarpAppleEvents.strings(window.atIndex(3)), browser: browser)
      })
    case .firefox:
      return nil
    }
  }

  private func pages(urls: [String?], titles: [String?], browser: TimeWarpBrowser) -> [TimeWarpItem] {
    urls.enumerated().compactMap { index, url in
      guard let url, let link = TimeWarpLink.storable(url) else { return nil }
      let title = index < titles.count ? titles[index] : nil
      return TimeWarpItem(kind: .page, value: link, title: TimeWarpTitleCleaner.pageTitle(title, browser: browser))
    }
  }

  private func classifiedTitles(pid: pid_t, profile: PrivateBrowsingProfile) -> (normal: Set<String>, other: Set<String>) {
    var normal = Set<String>()
    var other = Set<String>()
    for window in TimeWarpWindowReader.windows(pid: pid) {
      let facts = TimeWarpWindowReader.facts(of: window)
      guard let title = facts.title else { continue }
      if classifier.verdict(for: facts, profile: profile) == .normal {
        normal.insert(title)
      } else {
        other.insert(title)
        // A private window's title carries a marker the Apple Events name may not.
        for affix in profile.titleAffixes where affix.matches(title) {
          other.insert(String(title.dropFirst(affix.prefix.count).dropLast(affix.suffix.count)))
        }
      }
    }
    return (normal, other)
  }

  /// Without Apple Events: the page each normal window shows.
  private func windowPages(pid: pid_t, browser: TimeWarpBrowser, profile: PrivateBrowsingProfile) -> Set<TimeWarpItem> {
    var items = Set<TimeWarpItem>()
    for window in TimeWarpWindowReader.windows(pid: pid) {
      let facts = TimeWarpWindowReader.facts(of: window)
      guard classifier.verdict(for: facts, profile: profile) == .normal,
            let page = TimeWarpFrontReader.page(facts: facts, browser: browser) else { continue }
      items.insert(page)
    }
    return items
  }

  // MARK: Finder and documents

  private func finderFolders() -> Set<TimeWarpItem>? {
    let body = """
    set out to {}
    repeat with w in Finder windows
      try
        set end of out to URL of (target of w)
      end try
    end repeat
    return out
    """
    guard let result = appleEvents.run(bundleId: TimeWarpBrowserCatalog.finderBundleId, body: body) else { return nil }
    return Set(TimeWarpAppleEvents.strings(result).compactMap { url in
      url.flatMap(TimeWarpDocumentFilter.path(fromDocument:)).flatMap(TimeWarpFrontReader.fileItem(path:))
    })
  }

  private func documents(pid: pid_t) -> Set<TimeWarpItem> {
    Set(TimeWarpWindowReader.windows(pid: pid).compactMap { window in
      TimeWarpWindowReader.facts(of: window).document
        .flatMap(TimeWarpDocumentFilter.path(fromDocument:))
        .flatMap(TimeWarpFrontReader.fileItem(path:))
    })
  }

  private func capped(_ items: Set<TimeWarpItem>) -> Set<TimeWarpItem> {
    items.count <= Self.maxItemsPerApp ? items : Set(items.prefix(Self.maxItemsPerApp))
  }
}
