import AppKit

/// Reports which supported browsers are running. Apps the user already excludes are left out: the
/// capture filter hides them entirely, so there is nothing to detect.
final class PrivateBrowserObserver {
  private var tokens: [NSObjectProtocol] = []

  init(onChange: @escaping () -> Void) {
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let bundleId = app?.bundleIdentifier,
              PrivateBrowsingCatalog.profile(forBundleId: bundleId) != nil else { return }
        onChange()
      })
    }
  }

  func invalidate() {
    let center = NSWorkspace.shared.notificationCenter
    tokens.forEach(center.removeObserver)
    tokens.removeAll()
  }

  deinit {
    invalidate()
  }

  static func runningBrowsers(excluding excludedBundleIds: Set<String>) -> [pid_t: PrivateBrowsingProfile] {
    var running: [pid_t: PrivateBrowsingProfile] = [:]
    for app in NSWorkspace.shared.runningApplications {
      guard let bundleId = app.bundleIdentifier, !excludedBundleIds.contains(bundleId),
            let profile = PrivateBrowsingCatalog.profile(forBundleId: bundleId) else { continue }
      running[app.processIdentifier] = profile
    }
    return running
  }
}
