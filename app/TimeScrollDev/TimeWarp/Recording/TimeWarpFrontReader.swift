import Foundation

/// What the front window showed at one moment.
struct TimeWarpFrontObservation: Equatable {
  let appBundleId: String
  /// The page, file or folder in front, if one could be read.
  let item: TimeWarpItem?
  /// Nothing may be recorded: an excluded app, a private window, or a window not classified normal.
  let isBlocked: Bool
}

/// Reads the focused window of the front app. Runs on the recorder's queue; every Accessibility call
/// is bounded, so a hung app delays one read by a fraction of a second.
final class TimeWarpFrontReader {
  private let classifier = TimeWarpWindowClassifier()
  /// Finds iTerm2's current folder; set only while Apple Events may be used.
  var iTermFolder: ((pid_t) -> String?)?

  func read(pid: pid_t, bundleId: String, excluded: Set<String>) -> TimeWarpFrontObservation {
    let blocked = TimeWarpFrontObservation(appBundleId: bundleId, item: nil, isBlocked: true)
    guard !excluded.contains(bundleId) else { return blocked }
    guard let window = TimeWarpWindowReader.focusedWindow(pid: pid) else {
      return TimeWarpFrontObservation(appBundleId: bundleId, item: nil, isBlocked: false)
    }
    let facts = TimeWarpWindowReader.facts(of: window)
    let browser = TimeWarpBrowserCatalog.browser(forBundleId: bundleId)
    let profile = PrivateBrowsingCatalog.profile(forBundleId: bundleId)

    if browser != nil || profile != nil {
      let verdict = profile.map { classifier.verdict(for: facts, profile: $0) }
      let decision = TimeWarpPrivacyGate.decision(bundleId: bundleId, excluded: excluded, isBrowser: true,
                                                  profile: profile, verdict: verdict)
      guard decision == .allowed, let browser else { return blocked }
      return TimeWarpFrontObservation(appBundleId: bundleId, item: Self.page(facts: facts, browser: browser), isBlocked: false)
    }

    if bundleId == TimeWarpBrowserCatalog.iTermBundleId, let folder = iTermFolder?(pid) {
      return TimeWarpFrontObservation(appBundleId: bundleId, item: Self.fileItem(path: folder), isBlocked: false)
    }
    let item = facts.document.flatMap(TimeWarpDocumentFilter.path(fromDocument:)).flatMap(Self.fileItem(path:))
    return TimeWarpFrontObservation(appBundleId: bundleId, item: item, isBlocked: false)
  }

  func forgetWindows() {
    classifier.forgetAll()
  }

  static func page(facts: TimeWarpWindowFacts, browser: TimeWarpBrowser) -> TimeWarpItem? {
    var raw = browser.readsDocumentAttribute ? facts.document : nil
    if raw?.isEmpty != false { raw = TimeWarpWindowReader.webAreaURL(in: facts.element) }
    guard let raw, let link = TimeWarpLink.storable(raw) else { return nil }
    return TimeWarpItem(kind: .page, value: link, title: TimeWarpTitleCleaner.pageTitle(facts.title, browser: browser))
  }

  static func fileItem(path: String) -> TimeWarpItem? {
    guard let kind = TimeWarpDocumentFilter.kind(forPath: path) else { return nil }
    return TimeWarpItem(kind: kind, value: path, title: TimeWarpTitleCleaner.fileTitle(path: path))
  }
}
