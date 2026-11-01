import AppKit

/// Bundle id per process, so the blacklist check does not query LaunchServices for every window.
final class AXBundleIDCache {
    private let lock = NSLock()
    private var ids: [pid_t: String?] = [:]

    func bundleID(for pid: pid_t) -> String? {
        lock.lock()
        if let cached = ids[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        lock.lock()
        ids[pid] = .some(id)
        lock.unlock()
        return id
    }

    /// Forgets processes that no longer have windows on screen (pids can be reused).
    func retain(only pids: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        ids = ids.filter { pids.contains($0.key) }
    }
}
