import Foundation
import AppKit

extension AppDelegate {
    // MARK: - Status Item
    func setupStatusItem() {
        // Use a square status item and a template-size symbol to avoid oversize frames
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            // Initial icon - will be updated by updateStatusItemIcon() when capture state is known
            let symbol = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "TimeScroll")
            if let img = symbol {
                img.isTemplate = true
                btn.image = img
            } else {
                // Fallback to app icon but ensure template + scale down
                let appImg = NSImage(named: NSImage.applicationIconName)
                appImg?.isTemplate = true
                btn.image = appImg
            }
            btn.imagePosition = .imageOnly
            btn.imageScaling = .scaleProportionallyDown
        }
        item.menu = buildMenu()
        statusItem = item
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Capture status (disabled label)
        let status = NSMenuItem(title: captureStatusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // Start/Stop capture
        let toggle = NSMenuItem(title: toggleCaptureTitle(), action: #selector(toggleCapture), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        // Open App window
        let open = NSMenuItem(title: "Open TimeScroll", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        // Preferences
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        // Check for Updates…
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(onMenuCheckForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        if SettingsStore.shared.vaultEnabled {
            menu.addItem(.separator())
            let queued = VaultManager.shared.queuedCount
            if queued > 0 {
                let q = NSMenuItem(title: "Queued: \(queued)", action: nil, keyEquivalent: "")
                q.isEnabled = false
                menu.addItem(q)
            }
            if VaultManager.shared.isUnlocked {
                let lock = NSMenuItem(title: "Lock", action: #selector(onMenuLockNow), keyEquivalent: "")
                lock.target = self
                menu.addItem(lock)
            } else {
                let unlock = NSMenuItem(title: "Unlock…", action: #selector(onMenuUnlock), keyEquivalent: "")
                unlock.target = self
                menu.addItem(unlock)
            }
        }

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit TimeScroll", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        return menu
    }

    @objc func onMenuUnlock() {
        Task { await VaultManager.shared.unlock(presentingWindow: NSApp.keyWindow) }
    }

    @objc func onMenuLockNow() {
        VaultManager.shared.lock()
    }

    @objc func toggleCapture() {
        Task { @MainActor in
            let state = AppState.shared
            if state.isCapturing {
                await state.stopCaptureIfNeeded()
            } else {
                await state.startCaptureIfNeeded()
            }
            refreshMenu()
        }
    }

    @objc func openMainWindow() {
        showMainWindow()
        updateActivationPolicy()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func captureStatusText() -> String {
        let on = AppState.shared.isCapturing
        return on ? "Capture: On" : "Capture: Off"
    }

    func toggleCaptureTitle() -> String {
        AppState.shared.isCapturing ? "Stop Capture" : "Start Capture"
    }

    func refreshMenu() {
        // Rebuild the menu to refresh dynamic items
        statusItem?.menu = buildMenu()
        statusItem?.button?.appearsDisabled = false
        updateStatusItemIcon()
    }

    func updateStatusItemIcon() {
        guard let btn = statusItem?.button else { return }
        let isCapturing = AppState.shared.isCapturing
        let symbolName = isCapturing ? "record.circle.fill" : "camera.aperture"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TimeScroll")
        if let img = symbol {
            img.isTemplate = true
            btn.image = img
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuild dynamic titles when the user opens the menu
        refreshMenu()
    }
}
