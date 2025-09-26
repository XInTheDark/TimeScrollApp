//
//  TimeScrollApp.swift
//  TimeScroll
//
//  Created by Muzhen J on 9/18/25.
//

import SwiftUI
import AppKit

@main
struct TimeScrollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(SettingsStore.shared)
        }
        Settings {
            PreferencesView()
                .environmentObject(SettingsStore.shared)
        }
    }
}
