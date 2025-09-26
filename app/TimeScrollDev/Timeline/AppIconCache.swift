import AppKit

final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {
        cache.countLimit = 256
    }

    func icon(for bundleId: String) -> NSImage? {
        let key = bundleId as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

