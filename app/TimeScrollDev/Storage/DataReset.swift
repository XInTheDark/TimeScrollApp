import Foundation
import AppKit

enum DataReset {
    static func wipeAllAppData() {
        // Stop capture streams if any
        // Caller/UI can restart app afterwards
        let fm = FileManager.default
        // Remove the current storage root's data. A custom root is a folder the user picked and
        // may hold unrelated files, so only TimeScroll's own entries are removed there.
        StoragePaths.withSecurityScope {
            let root = StoragePaths.currentRoot()
            if StoragePaths.isDefaultRoot(root) {
                if fm.fileExists(atPath: root.path) {
                    try? fm.removeItem(at: root)
                }
            } else {
                for entry in StoragePaths.storageEntries(in: root) {
                    try? fm.removeItem(at: entry)
                }
            }
        }
        // The vault key and MCP log would otherwise outlive the data they belong to.
        VaultKeychainStore.delete()
        try? fm.removeItem(at: StoragePaths.sharedLogURL(filename: "timescroll-mcp.log"))
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
