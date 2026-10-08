import AppKit

/// Reports when the user activates a different app, so capture can take a snapshot right away
/// instead of waiting for the next interval. Activations of TimeScroll itself are ignored.
final class AppSwitchObserver {
    private var token: NSObjectProtocol?

    init(onSwitch: @escaping () -> Void) {
        let ownBundleId = Bundle.main.bundleIdentifier
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let ownBundleId, app?.bundleIdentifier == ownBundleId { return }
            guard SettingsStore.AppSwitchCaptureMode.current() != .off else { return }
            onSwitch()
        }
    }

    func invalidate() {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        token = nil
    }

    deinit {
        invalidate()
    }
}
