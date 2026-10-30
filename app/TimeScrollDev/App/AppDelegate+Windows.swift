import Foundation
import AppKit
import SwiftUI

extension AppDelegate {
    func showMainWindow() {
        // Reuse the SwiftUI scene's window (id "main") even while hidden, e.g. by "start minimized";
        // a second timeline window would duplicate the model, live refresh and key handling.
        let sceneWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" }
        if let window = sceneWindow ?? mainWC?.window {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = ContentView().environmentObject(SettingsStore.shared)
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        win.title = "TimeScroll"
        win.setContentSize(NSSize(width: 1000, height: 700))
        win.contentMinSize = NSSize(width: 1000, height: 700)
        win.identifier = NSUserInterfaceItemIdentifier("MainWindow")
        let wc = NSWindowController(window: win)
        wc.window?.isReleasedWhenClosed = false
        mainWC = wc
        NSApp.setActivationPolicy(.regular)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboardingWindow() {
        if onboardingWC == nil {
            let root = OnboardingView().environmentObject(SettingsStore.shared)
            let hosting = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: hosting)
            win.styleMask.insert([.titled, .closable])
            win.title = "TimeScroll Setup"
            win.setContentSize(NSSize(width: 640, height: 540))
            win.isMovableByWindowBackground = true
            win.center()
            win.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")
            let wc = NSWindowController(window: win)
            wc.window?.isReleasedWhenClosed = false
            onboardingWC = wc
        }
        NSApp.setActivationPolicy(.regular)
        onboardingWC?.showWindow(nil)
        onboardingWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openPreferences() {
        DispatchQueue.main.async { [weak self] in
            self?.presentPreferencesWindow()
        }
    }

    private func presentPreferencesWindow() {
        prepareForForegroundWindowPresentation()

        if openSystemSettingsWindowIfAvailable() {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        // shouldn't be needed
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
            prefsWC = wc
        }
        prefsWC?.showWindow(nil)
        prefsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func prepareForForegroundWindowPresentation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSystemSettingsWindowIfAvailable() -> Bool {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return true
        }
        if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) {
            return true
        }
        return false
    }
}
