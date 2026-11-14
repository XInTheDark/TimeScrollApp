import AppKit
import Foundation

/// Opens the items the user chose: pages in the browser they were viewed in, files in the app they
/// were open in, terminal folders in that terminal. Every item is checked
/// again right before opening (`TimeWarpOpenSafety`).
@MainActor
enum TimeWarpLauncher {
  struct Result: Equatable {
    var opened = 0
    var missing = 0
    var refused = 0
    /// Passed the checks, but the app that should open it reported an error.
    var failed = 0
    /// Left out because it was already open.
    var alreadyOpen = 0

    /// Nothing was opened because everything chosen was already open.
    var wasAllOpen: Bool { opened == 0 && notOpened == 0 && alreadyOpen > 0 }

    var notOpened: Int { missing + refused + failed }
    var isComplete: Bool { notOpened == 0 }
  }

  static let terminalBundleIds: Set<String> = [TimeWarpBrowserCatalog.terminalBundleId, TimeWarpBrowserCatalog.iTermBundleId]

  static func open(_ items: [TimeWarpPlanItem], inNewWindow: Bool) async -> Result {
    var result = Result()
    var pagesByBrowser: [String?: [URL]] = [:]
    var filesByApp: [URL?: [URL]] = [:]
    var apps: [URL] = []
    var foldersByApp: [URL?: [URL]] = [:]

    for item in items {
      switch TimeWarpOpenSafety.check(item) {
      case let .web(url):
        let browser = item.appBundleId.flatMap { TimeWarpBrowserCatalog.browser(forBundleId: $0) != nil ? $0 : nil }
        pagesByBrowser[browser, default: []].append(url)
      case let .file(url, app):
        filesByApp[app, default: []].append(url)
      case let .folder(url):
        let terminal = item.appBundleId.flatMap { terminalBundleIds.contains($0) ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) : nil }
        foldersByApp[terminal, default: []].append(url)
      case let .app(url):
        apps.append(url)
      case .missing:
        result.missing += 1
        continue
      case .refused:
        result.refused += 1
      }
    }

    // Each step reports how many of its items Launch Services accepted.
    func tally(_ opened: Int, of count: Int) {
      result.opened += opened
      result.failed += count - opened
    }
    for url in apps { tally(await openApplication(url) ? 1 : 0, of: 1) }
    for (bundleId, urls) in pagesByBrowser {
      if inNewWindow, let bundleId, await openInNewWindow(urls, bundleId: bundleId) {
        tally(urls.count, of: urls.count)
        continue
      }
      tally(await open(urls, with: bundleId.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }), of: urls.count)
    }
    for (app, urls) in filesByApp { tally(await open(urls, with: app), of: urls.count) }
    for (app, urls) in foldersByApp {
      if let app {
        // A terminal opens one window per folder.
        for url in urls { tally(await open([url], with: app), of: 1) }
      } else {
        tally(await open(urls, with: nil), of: urls.count)
      }
    }
    return result
  }

  /// Returns how many of `urls` were opened.
  private static func open(_ urls: [URL], with app: URL?) async -> Int {
    guard !urls.isEmpty else { return 0 }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    if let app {
      // One request for all of them: it succeeds or fails as a whole.
      return (try? await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)) != nil ? urls.count : 0
    }
    var opened = 0
    for url in urls where (try? await NSWorkspace.shared.open(url, configuration: configuration)) != nil { opened += 1 }
    return opened
  }

  private static func openApplication(_ url: URL) async -> Bool {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
  }

  /// Opens the pages as tabs of a new window, over Apple Events. False if that is not possible,
  /// so the caller opens them the usual way.
  private static func openInNewWindow(_ urls: [URL], bundleId: String) async -> Bool {
    guard let browser = TimeWarpBrowserCatalog.browser(forBundleId: bundleId), browser.listsTabsOverAppleEvents,
          !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty, !urls.isEmpty else { return false }
    // Addresses are already valid URLs; quotes and backslashes are escaped so none can end the string.
    let quoted = urls.map { "\"\($0.absoluteString.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "\"", with: "%22"))\"" }
    let opening = browser.family == .safari
      ? "make new document with properties {URL:\(quoted[0])}"
      : "make new window\nset URL of active tab of window 1 to \(quoted[0])"
    let rest = quoted.dropFirst().map { "tell window 1 to make new tab with properties {URL:\($0)}" }.joined(separator: "\n")
    let body = "\(opening)\n\(rest)\nactivate\nreturn true"
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let ok = TimeWarpAppleEvents().run(bundleId: bundleId, body: body, timeoutSeconds: 30)?.booleanValue ?? false
        continuation.resume(returning: ok)
      }
    }
  }
}
