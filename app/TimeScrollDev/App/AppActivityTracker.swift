import AppKit

final class AppActivityTracker {
    static let shared = AppActivityTracker()
    private init() {
        // Seed initial value from frontmost app on main
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let app = NSWorkspace.shared.frontmostApplication
            self.setCurrent(bundleId: app?.bundleIdentifier, name: app?.localizedName)
        }
        // Observe app activation to keep current app fresh
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.setCurrent(bundleId: app.bundleIdentifier, name: app.localizedName)
        }
    }

    private let lock = NSLock()
    private var _bundleId: String?
    private var _name: String?

    private func setCurrent(bundleId: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        _bundleId = bundleId
        _name = name
    }

    func current() -> (bundleId: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_bundleId, _name)
    }
}

