import ApplicationServices
import CoreGraphics
import Foundation

/// Remembers which Accessibility window belongs to each on-screen CG window. A window id lives as
/// long as its window, so once matched, a window costs no further IPC to find; only unknown ids
/// fetch the app's window list (with a deadline) and match by frame. A window that matched nothing
/// is retried only after `missRetryInterval`, so it does not cost a window-list fetch every time.
final class AXWindowDirectory {
    static let missRetryInterval: TimeInterval = 10

    private let lock = NSLock()
    private var windows: [CGWindowID: AXElementRef] = [:]
    private var misses: [CGWindowID: TimeInterval] = [:]

    /// The Accessibility window for each of `targets` (all windows of `app`), nil where none matched.
    func axWindows(for targets: [AXScreenWindow], app: AXUIElement,
                   source: AXLiveNodeSource, deadline: AXDeadline, now: TimeInterval) -> [AXElementRef?] {
        lock.lock()
        var found = targets.map { windows[$0.id] }
        let shouldLookUp = targets.indices.contains { index in
            found[index] == nil && (misses[targets[index].id].map { now - $0 >= Self.missRetryInterval } ?? true)
        }
        lock.unlock()
        guard shouldLookUp else { return found }

        // Unknown windows: fetch the app's windows once and match each unknown target by frame.
        guard let remaining = deadline.remainingSeconds() else { return found }
        AXUIElementSetMessagingTimeout(app, max(remaining, 0.001))
        var listRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &listRef) == .success,
              let list = listRef as? [AXUIElement], !list.isEmpty else {
            recordMisses(targets, found: found, now: now)
            return found
        }
        let known = Set(found.compactMap { $0 })
        let candidates = list.map(AXElementRef.init).filter { !known.contains($0) }
        var frames = candidates.map { source.frame($0, deadline: deadline) }

        lock.lock()
        defer { lock.unlock() }
        for (index, target) in targets.enumerated() where found[index] == nil {
            guard let match = AXWindowMatcher.bestMatch(for: target.bounds, among: frames) else {
                misses[target.id] = now
                continue
            }
            found[index] = candidates[match]
            windows[target.id] = candidates[match]
            misses[target.id] = nil
            frames[match] = nil
        }
        return found
    }

    private func recordMisses(_ targets: [AXScreenWindow], found: [AXElementRef?], now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        for (index, target) in targets.enumerated() where found[index] == nil { misses[target.id] = now }
    }

    /// Forgets windows that are no longer on screen.
    func retain(only ids: Set<CGWindowID>) {
        lock.lock()
        defer { lock.unlock() }
        windows = windows.filter { ids.contains($0.key) }
        misses = misses.filter { ids.contains($0.key) }
    }
}
