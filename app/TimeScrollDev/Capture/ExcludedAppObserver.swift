import AppKit

/// Reports when an app launches or quits, so capture can keep track of running excluded apps.
final class ExcludedAppObserver {
    private var tokens: [NSObjectProtocol] = []

    init(onChange: @escaping () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleId = app?.bundleIdentifier,
                      Self.storedBundleIds().contains(bundleId) else { return }
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

    static func storedBundleIds() -> Set<String> {
        Set(UserDefaults.standard.array(forKey: "settings.blacklistBundleIds") as? [String] ?? [])
    }

    static func runningPIDs(bundleIds: Set<String>) -> Set<pid_t> {
        guard !bundleIds.isEmpty else { return [] }
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.flatMap { bundleIds.contains($0) ? app.processIdentifier : nil }
        })
    }
}
