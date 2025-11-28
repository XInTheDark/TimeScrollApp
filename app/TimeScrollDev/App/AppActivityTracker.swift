import AppKit

final class AppActivityTracker {
    static let shared = AppActivityTracker()
    private init() {
        // Seed initial value from frontmost app immediately
        let app = NSWorkspace.shared.frontmostApplication
        _bundleId = app?.bundleIdentifier
        _name = app?.localizedName
        
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

