import Foundation
import AppKit

enum DataReset {
    static func wipeAllAppData() {
        // Stop capture streams if any
        // Caller/UI can restart app afterwards
        let fm = FileManager.default
        // Remove current storage root (may be custom folder)
        StoragePaths.withSecurityScope {
            let root = StoragePaths.currentRoot()
            if fm.fileExists(atPath: root.path) {
                try? fm.removeItem(at: root)
            }
        }
        // Also delete the default Application Support folder if different, to ensure full reset
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultDir = appSupport.appendingPathComponent("TimeScroll", isDirectory: true)
        if defaultDir.path != StoragePaths.currentRoot().path, fm.fileExists(atPath: defaultDir.path) {
            try? fm.removeItem(at: defaultDir)
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
