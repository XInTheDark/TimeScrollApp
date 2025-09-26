import Foundation
import AppKit

enum DataReset {
    static func wipeAllAppData() {
        // Stop capture streams if any
        // Caller/UI can restart app afterwards
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("TimeScroll", isDirectory: true)
        // Remove Application Support subtree
        if fm.fileExists(atPath: appDir.path) {
            try? fm.removeItem(at: appDir)
        }
        // Remove preferences
        let bundleId = Bundle.main.bundleIdentifier ?? "com.muzhen.TimeScroll"
        let prefs = appSupport.deletingLastPathComponent().appendingPathComponent("Preferences/\(bundleId).plist")
        if fm.fileExists(atPath: prefs.path) {
            try? fm.removeItem(at: prefs)
        }
        // Clear NSCache-backed thumbnails implicitly by process lifetime; force quit recommended
        // Notify and quit to ensure clean state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
        }
    }
}

