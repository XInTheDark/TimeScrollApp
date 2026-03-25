import Foundation
import AppKit
import SwiftUI

extension AppDelegate {
    func showMainWindow() {
        if let window = mainWC?.window {
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
            win.setContentSize(NSSize(width: 640, height: 380))
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
            prefsWC = wc
        }
        NSApp.setActivationPolicy(.regular)
        prefsWC?.showWindow(nil)
        prefsWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
