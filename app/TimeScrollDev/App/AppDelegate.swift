import Foundation
import AppKit
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

extension Notification.Name {
    static let TimeScrollCheckForUpdates = Notification.Name("TimeScroll.CheckForUpdates")
    static let TimeScrollApplyUpdatePrefs = Notification.Name("TimeScroll.ApplyUpdatePrefs")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsObserver: NSObjectProtocol?
    private var menuNeedsRefresh: Bool = true
    private var prefsWC: NSWindowController?
    private var mainWC: NSWindowController?
    private var updateNotiTokens: [NSObjectProtocol] = []
    private var powerNotiTokens: [NSObjectProtocol] = []
    private var lastWakeRestartAt: TimeInterval = 0
    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController!
    private var updatesDelegate: UpdatesDelegate!
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[App] applicationDidFinishLaunching")
        let bundleId = Bundle.main.bundleIdentifier ?? "(nil)"
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.path ?? "(unknown)"
        print("[Prefs] Launch bundle=\(bundleId) libraryDir=\(lib)")
        // Seed App Group defaults so the MCP helper can see storage bookmarks/paths immediately
        StoragePaths.syncSharedDefaultsFromStandard()
        setupStatusItem()

        // Sparkle updater (if available)
        #if canImport(Sparkle)
        self.updatesDelegate = UpdatesDelegate()
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updatesDelegate,
            userDriverDelegate: nil
        )
        print("[Sparkle] SPUStandardUpdaterController initialized")
        applySparklePrefsFromSettings()
        // Optional: initial background check shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if SettingsStore.sharedEnableAutoCheckUpdatesSnapshot() {
                self.updaterController.updater.checkForUpdatesInBackground()
                print("[Sparkle] Scheduled initial background update check")
            }
        }
        #endif

        // Apply start-minimized and dock visibility policy
        DispatchQueue.main.async { [weak self] in
            // Load vault prefs
            VaultManager.shared.loadPrefs()
            self?.applyStartMinimizedIfNeeded()
            self?.updateActivationPolicy()
            self?.installSettingsObservers()
            self?.installWindowObservers()
            self?.installUpdateNotificationObservers()
            self?.installSleepWakeObservers()
            self?.applyAutoStartCaptureIfNeeded()
            // Prompt unlock if vault is enabled
            if SettingsStore.shared.vaultEnabled {
                Task { await VaultManager.shared.unlock(presentingWindow: NSApp.keyWindow) }
            }
        }
    }

    deinit {
        for t in updateNotiTokens { NotificationCenter.default.removeObserver(t) }
        updateNotiTokens.removeAll()
        for t in powerNotiTokens { NotificationCenter.default.removeObserver(t) }
        powerNotiTokens.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SettingsStore.shared.vaultEnabled {
            VaultManager.shared.lock()
        }
        SettingsStore.shared.flush()
        // Ensure any open HEVC writers are flushed (best-effort with timeout)
        HEVCVideoStore.shared.shutdown(timeout: 2.0)
        UsageTracker.shared.appWillTerminate()
        UserDefaults.standard.synchronize()
    }

    // MARK: - Status Item
    private func setupStatusItem() {
        // Use a square status item and a template-size symbol to avoid oversize frames
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            let symbol = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "TimeScroll")
                ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "TimeScroll")
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
        self.statusItem = item
    }

    private func buildMenu() -> NSMenu {
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

    @objc private func onMenuUnlock() { Task { await VaultManager.shared.unlock(presentingWindow: NSApp.keyWindow) } }
    @objc private func onMenuLockNow() { VaultManager.shared.lock() }

    @objc private func toggleCapture() {
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

    @objc private func openMainWindow() {
        // Always show dock when a window is visible
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let win = NSApp.windows.first { win.makeKeyAndOrderFront(nil) }
        else { showMainWindow() }

        updateActivationPolicy()
    }

    private func showMainWindow() {
        let hosting = NSHostingController(rootView: ContentView())
        let win = NSWindow(contentViewController: hosting)
        win.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        win.title = "TimeScroll"
        win.setContentSize(NSSize(width: 1000, height: 700))
        let wc = NSWindowController(window: win)
        wc.window?.isReleasedWhenClosed = false
        self.mainWC = wc
        wc.showWindow(nil)
    }

    @objc private func openPreferences() {
        // Prefer the system-standard SwiftUI Settings window if available
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return
        }
        if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) {
            return
        }

        // Fallback: create a simple, resizable window with a sensible minimum size
        if prefsWC == nil {
            let root = PreferencesView().environmentObject(SettingsStore.shared)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
            win.title = "Preferences"
            win.setContentSize(NSSize(width: 760, height: 520))
            win.contentMinSize = NSSize(width: 640, height: 400)
            let wc = NSWindowController(window: win)
            wc.window?.isReleasedWhenClosed = false
            self.prefsWC = wc
        }
        NSApp.setActivationPolicy(.regular)
        prefsWC?.showWindow(nil)
        prefsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Updates
    @objc func checkForUpdates(_ sender: Any?) {
        NotificationCenter.default.post(name: .TimeScrollCheckForUpdates, object: nil)
    }
    @objc private func onMenuCheckForUpdates(_ sender: Any?) {
        NotificationCenter.default.post(name: .TimeScrollCheckForUpdates, object: nil)
    }

    // Convenience for SwiftUI/others
    func checkForUpdates() { checkForUpdates(nil) }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func captureStatusText() -> String {
        let on = AppState.shared.isCapturing
        return on ? "Capture: On" : "Capture: Off"
    }

    private func toggleCaptureTitle() -> String {
        AppState.shared.isCapturing ? "Stop Capture" : "Start Capture"
    }

    private func refreshMenu() {
        // Rebuild the menu to refresh dynamic items
        statusItem?.menu = buildMenu()
        statusItem?.button?.appearsDisabled = false
    }

    // MARK: - Dock icon policy
    private func applyStartMinimizedIfNeeded() {
        let d = UserDefaults.standard
        let startMin = d.object(forKey: "settings.startMinimized") != nil ? d.bool(forKey: "settings.startMinimized") : false
        if startMin {
            for w in NSApp.windows { w.orderOut(nil) }
            NSApp.hide(nil)
        }
    }

    private func installSettingsObservers() {
        // Observe settings changes on main actor
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateActivationPolicy()
            }
        }
        // Polling approach is unnecessary; just update on demand using a KVO of windows and toggles below.
    }

    private func installWindowObservers() {
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

    private func installUpdateNotificationObservers() {
        let nc = NotificationCenter.default
        let t1 = nc.addObserver(forName: .TimeScrollApplyUpdatePrefs, object: nil, queue: .main) { [weak self] _ in
            #if canImport(Sparkle)
            Task { @MainActor in self?.applySparklePrefsFromSettings() }
            #endif
        }
        let t2 = nc.addObserver(forName: .TimeScrollCheckForUpdates, object: nil, queue: .main) { [weak self] _ in
            #if canImport(Sparkle)
            print("[Sparkle] Notification received: TimeScrollCheckForUpdates")
            Task { @MainActor in
                guard let strongSelf = self else { return }
                let up = strongSelf.updaterController.updater
                if up.canCheckForUpdates {
                    strongSelf.updaterController.checkForUpdates(nil)
                } else {
                    print("[Sparkle] Ignoring manual check; a session is already in progress")
                }
            }
            #else
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Updates Unavailable"
            alert.informativeText = "Sparkle is not integrated. Add the Sparkle package to enable update checks."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            #endif
        }
        updateNotiTokens.append(contentsOf: [t1, t2])
    }

    // MARK: - Sleep/Wake handling
    private func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
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
        let t1 = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler)
        powerNotiTokens.append(contentsOf: [t1])
    }

    private func updateActivationPolicy() {
        let anyVisible = NSApp.windows.contains { $0.isVisible }
        if anyVisible {
            NSApp.setActivationPolicy(.regular)
            return
        }
        let d = UserDefaults.standard
        let showDock = d.object(forKey: "settings.showDockIcon") != nil ? d.bool(forKey: "settings.showDockIcon") : true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    private func applyAutoStartCaptureIfNeeded() {
        let d = UserDefaults.standard
        let auto = d.object(forKey: "settings.startRecordingOnStart") != nil ? d.bool(forKey: "settings.startRecordingOnStart") : true
        guard auto else { return }
        Task { @MainActor in
            await AppState.shared.startCaptureIfNeeded()
            self.refreshMenu()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuild dynamic titles when the user opens the menu
        refreshMenu()
    }
}

#if canImport(Sparkle)
// MARK: - Sparkle integration
extension AppDelegate {
    func applySparklePrefsFromSettings() {
        let s = SettingsStore.shared
        let up = updaterController.updater
        up.automaticallyChecksForUpdates = s.enableAutoCheckUpdates
        up.updateCheckInterval = TimeInterval(max(1, s.autoCheckIntervalHours)) * 3600
        up.automaticallyDownloadsUpdates = s.autoDownloadInstallUpdates
        print("[Sparkle] applySparklePrefsFromSettings auto=\(s.enableAutoCheckUpdates) intervalH=\(s.autoCheckIntervalHours) autoDL=\(s.autoDownloadInstallUpdates)")
    }

}

final class UpdatesDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        let d = UserDefaults.standard
        let useBeta = (d.object(forKey: "settings.updateChannelBeta") != nil) ? d.bool(forKey: "settings.updateChannelBeta") : false
        let url = useBeta ? "https://timescroll.updates.muzhen.org/beta/appcast.xml" : "https://timescroll.updates.muzhen.org/stable/appcast.xml"
        print("[Sparkle] feedURLString=\(url)")
        return url
    }
}

// Helper to safely snapshot the auto-check flag from UserDefaults when off-main contexts are involved
@MainActor
fileprivate extension SettingsStore {
    static func sharedEnableAutoCheckUpdatesSnapshot() -> Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "settings.enableAutoCheckUpdates") != nil {
            return d.bool(forKey: "settings.enableAutoCheckUpdates")
        }
        return true
    }
}
#endif
