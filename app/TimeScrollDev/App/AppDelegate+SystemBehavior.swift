import Foundation
import AppKit

extension AppDelegate {
    // MARK: - Dock icon policy
    func applyStartMinimizedIfNeeded() {
        let d = UserDefaults.standard
        let startMin = d.object(forKey: "settings.startMinimized") != nil ? d.bool(forKey: "settings.startMinimized") : false
        if startMin {
            for w in NSApp.windows { w.orderOut(nil) }
            NSApp.hide(nil)
        }
    }

    func installSettingsObservers() {
        // Observe settings changes on main actor
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateActivationPolicy()
            }
        }
        // Polling approach is unnecessary; just update on demand using a KVO of windows and toggles below.
    }

    func installWindowObservers() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateActivationPolicy()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            // Defer to ensure window list updates
            DispatchQueue.main.async {
                Task { @MainActor in
                    self?.updateActivationPolicy()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateActivationPolicy()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateActivationPolicy()
            }
        }
    }

    // MARK: - Sleep/Wake handling
    func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            if now - self.lastWakeRestartAt < 2.0 { return }
            self.lastWakeRestartAt = now
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                await AppState.shared.restartCaptureIfRunning()
                self.refreshMenu()
                if SettingsStore.shared.autoLockOnSleep { VaultManager.shared.lock() }
            }
        }
        let token = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler)
        powerNotiTokens.append(token)
    }

    func updateActivationPolicy() {
        let anyVisible = NSApp.ts_hasVisibleUserWindow
        if anyVisible {
            NSApp.setActivationPolicy(.regular)
            return
        }
        let d = UserDefaults.standard
        let showDock = d.object(forKey: "settings.showDockIcon") != nil ? d.bool(forKey: "settings.showDockIcon") : true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    func applyAutoStartCaptureIfNeeded() {
        let d = UserDefaults.standard
        let auto = d.object(forKey: "settings.startRecordingOnStart") != nil ? d.bool(forKey: "settings.startRecordingOnStart") : true
        guard auto else { return }
        guard Permissions.isScreenRecordingGranted() else { return }
        Task { @MainActor in
            await AppState.shared.startCaptureIfNeeded()
            refreshMenu()
        }
    }
}
