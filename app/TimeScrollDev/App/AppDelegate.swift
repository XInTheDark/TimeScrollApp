import Foundation
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

// Windows: helper to ignore the status bar host window when deciding whether
// the app currently has a user-facing window. The status item always keeps an
// NSStatusBarWindow alive and visible, which would otherwise prevent us from
// hiding the Dock icon.
extension NSApplication {
    var ts_hasVisibleUserWindow: Bool {
        let statusBarWindowClass: AnyClass? = NSClassFromString("NSStatusBarWindow")
        return windows.contains { window in
            guard window.isVisible else { return false }
            // Exclude the system status bar host window and any other status-bar-level windows
            if let cls = statusBarWindowClass, window.isKind(of: cls) { return false }
            if window.level == .statusBar { return false }
            return true
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var prefsWC: NSWindowController?
    var mainWC: NSWindowController?
    var onboardingWC: NSWindowController?
    var updateNotiTokens: [NSObjectProtocol] = []
    var powerNotiTokens: [NSObjectProtocol] = []
    var lastWakeRestartAt: TimeInterval = 0
    #if canImport(Sparkle)
    var updaterController: SPUStandardUpdaterController!
    var updatesDelegate: UpdatesDelegate!
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
        updatesDelegate = UpdatesDelegate()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updatesDelegate,
            userDriverDelegate: nil
        )
        print("[Sparkle] SPUStandardUpdaterController initialized")
        applySparklePrefsFromSettings()
        // Optional: initial background check shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            if SettingsStore.sharedEnableAutoCheckUpdatesSnapshot() {
                updaterController.updater.checkForUpdatesInBackground()
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
            StorageMaintenanceManager.shared.start()
            // Show onboarding if permissions are missing; otherwise honor auto-start
            if !Permissions.isScreenRecordingGranted() {
                self?.showOnboardingWindow()
            } else {
                self?.applyAutoStartCaptureIfNeeded()
            }
            // Prompt unlock if vault is enabled
            if SettingsStore.shared.vaultEnabled {
                Task { await VaultManager.shared.unlock(presentingWindow: NSApp.keyWindow) }
            }
        }
    }

    deinit {
        for token in updateNotiTokens { NotificationCenter.default.removeObserver(token) }
        updateNotiTokens.removeAll()
        for token in powerNotiTokens { NotificationCenter.default.removeObserver(token) }
        powerNotiTokens.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SettingsStore.shared.vaultEnabled {
            VaultManager.shared.lock()
        }
        SettingsStore.shared.flush()
        // Ensure any open HEVC writers are flushed (best-effort with timeout)
        HEVCVideoStore.shared.shutdown(timeout: 2.0)
        StorageMaintenanceManager.shared.stop()
        UsageTracker.shared.appWillTerminate()
        UserDefaults.standard.synchronize()
    }
}
