import AppKit

final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var inFlight = Set<String>()
    private var waiters: [String: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 256
    }

    func cachedIcon(for bundleId: String) -> NSImage? {
        cache.object(forKey: bundleId as NSString)
    }

    func icon(for bundleId: String) -> NSImage? {
        let key = bundleId as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let icon = resolveIcon(for: bundleId) else { return nil }
        cache.setObject(icon, forKey: key)
        return icon
    }

    func loadIconAsync(for bundleId: String, completion: ((NSImage?) -> Void)? = nil) {
        let key = bundleId as NSString
        if let cached = cache.object(forKey: key) {
            completion?(cached)
            return
        }

        lock.lock()
        if let completion {
            waiters[bundleId, default: []].append(completion)
        }
        if inFlight.contains(bundleId) {
            lock.unlock()
            return
        }
        inFlight.insert(bundleId)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let icon = self.resolveIcon(for: bundleId)
            if let icon {
                self.cache.setObject(icon, forKey: key)
            }

            self.lock.lock()
            let callbacks = self.waiters.removeValue(forKey: bundleId) ?? []
            self.inFlight.remove(bundleId)
            self.lock.unlock()

            callbacks.forEach { $0(icon) }
        }
    }

    private func resolveIcon(for bundleId: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}
