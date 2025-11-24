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
    init() {
        // Ensure App Group defaults are ready before any StoragePaths usage
        StoragePaths.syncSharedDefaultsFromStandard()
        
        // Migration: Move default storage from App Sandbox to App Group if needed
        // Only perform this if the user hasn't selected a custom storage location (bookmarkKey is nil)
        if StoragePaths.sharedDefaults.data(forKey: StoragePaths.bookmarkKey) == nil {
            let legacy = StoragePaths.legacyDefaultRoot()
            let newRoot = StoragePaths.defaultRoot()   // App Group path
            let fm = FileManager.default
            
            // If legacy exists and new doesn't, move it
            if fm.fileExists(atPath: legacy.path) && !fm.fileExists(atPath: newRoot.path) {
                // Ensure parent of newRoot exists
                try? fm.createDirectory(at: newRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try fm.moveItem(at: legacy, to: newRoot)
                    print("[Migration] Moved default storage to App Group container")
                } catch {
                    print("[Migration] Failed to move storage: \(error)")
                }
            }
        }
        StoragePaths.ensureStorageDisplayPathRecorded()

        // Mirror vaultEnabled flag into App Group so DB/SQLCipher see consistent state on first launch
        let std = UserDefaults.standard
        let grp = UserDefaults(suiteName: StoragePaths.appGroupID) ?? .standard
        if std.object(forKey: "settings.vaultEnabled") != nil {
            grp.set(std.bool(forKey: "settings.vaultEnabled"), forKey: "settings.vaultEnabled")
            grp.synchronize()
        }
    }
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
