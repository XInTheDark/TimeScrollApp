import AppKit

/// Resolves which captured display is "active": the one holding the frontmost app's frontmost
/// window, or the one under the mouse when that app has no window. Used by the "Active display"
/// capture mode so only that display's stream persists frames.
/// Only called from the capture output queue, so the cache needs no lock.
final class ActiveDisplayTracker {
    private static let cacheDuration: TimeInterval = 0.5

    private let displayIDs: [CGDirectDisplayID]
    private var cached: CGDirectDisplayID?
    private var cachedAt: TimeInterval = -.infinity

    init(displayIDs: [CGDirectDisplayID]) {
        self.displayIDs = displayIDs
    }

    func isActive(_ displayID: CGDirectDisplayID) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedAt > Self.cacheDuration {
            cached = resolve()
            cachedAt = now
        }
        return cached == displayID
    }

    private func resolve() -> CGDirectDisplayID? {
        let pid = AppActivityTracker.shared.currentProcessIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // The list is front-to-back, so the first normal-layer window of the app is its frontmost.
        let window = windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        if let boundsDict = window?[kCGWindowBounds as String] as? NSDictionary,
           let frame = CGRect(dictionaryRepresentation: boundsDict),
           let best = displayIDs.max(by: { overlap(frame, $0) < overlap(frame, $1) }),
           overlap(frame, best) > 0 {
            return best
        }
        let mouse = CGEvent(source: nil)?.location ?? .zero
        return displayIDs.first { CGDisplayBounds($0).contains(mouse) } ?? displayIDs.first
    }

    private func overlap(_ frame: CGRect, _ displayID: CGDirectDisplayID) -> CGFloat {
        let visible = frame.intersection(CGDisplayBounds(displayID))
        return visible.isNull ? 0 : visible.width * visible.height
    }
}
