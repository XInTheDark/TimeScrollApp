import Foundation
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

extension Notification.Name {
    static let TimeScrollCheckForUpdates = Notification.Name("TimeScroll.CheckForUpdates")
    static let TimeScrollApplyUpdatePrefs = Notification.Name("TimeScroll.ApplyUpdatePrefs")
}

extension AppDelegate {
    // MARK: - Updates
    @objc func checkForUpdates(_ sender: Any?) {
        NotificationCenter.default.post(name: .TimeScrollCheckForUpdates, object: nil)
    }

    @objc func onMenuCheckForUpdates(_ sender: Any?) {
        NotificationCenter.default.post(name: .TimeScrollCheckForUpdates, object: nil)
    }

    // Convenience for SwiftUI/others
    func checkForUpdates() {
        checkForUpdates(nil)
    }

    func installUpdateNotificationObservers() {
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
                guard let self else { return }
                let up = self.updaterController.updater
                if up.canCheckForUpdates {
                    self.updaterController.checkForUpdates(nil)
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
        let t3 = nc.addObserver(forName: NSNotification.Name("ShowOnboarding"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.showOnboardingWindow()
            }
        }
        updateNotiTokens.append(contentsOf: [t1, t2, t3])
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
extension SettingsStore {
    static func sharedEnableAutoCheckUpdatesSnapshot() -> Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "settings.enableAutoCheckUpdates") != nil {
            return d.bool(forKey: "settings.enableAutoCheckUpdates")
        }
        return true
    }
}
#endif
