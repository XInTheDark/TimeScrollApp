import CoreGraphics
import CoreMedia
import Foundation

/// Decides whether a captured frame could show an excluded app that the stream filter does not
/// cover yet. ScreenCaptureKit can only exclude apps it already lists, so an app that opens after
/// the filter was built stays visible until the filter is rebuilt; frames are dropped until then.
/// While every running excluded app is covered, a check costs one lock and no window-list call.
final class ExcludedAppGate: @unchecked Sendable {
    static let refreshInterval: TimeInterval = 1

    private let lock = NSLock()
    private var uncovered: Set<pid_t> = []
    private var covered: Set<pid_t> = []
    private var coveredAt: CMTime = .zero
    private var lastRefreshRequest: TimeInterval?

    private let windowList: () -> [AXScreenWindow]
    private let uptime: () -> TimeInterval
    private let onRefreshNeeded: () -> Void

    init(windowList: @escaping () -> [AXScreenWindow] = ExcludedAppGate.liveWindowList,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onRefreshNeeded: @escaping () -> Void) {
        self.windowList = windowList
        self.uptime = uptime
        self.onRefreshNeeded = onRefreshNeeded
    }

    /// Records the running excluded apps, for example after one launched or quit.
    func updateRunning(_ running: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        uncovered = running.subtracting(covered)
    }

    /// Records the apps the stream filters now exclude. Frames captured before `time` may predate
    /// the new filter, so they are dropped when the filter gained an app.
    func updateCovered(_ newCovered: Set<pid_t>, running: Set<pid_t>, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        if !newCovered.isSubset(of: covered) { coveredAt = time }
        covered = newCovered
        uncovered = running.subtracting(newCovered)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        uncovered = []
        covered = []
        coveredAt = .zero
        lastRefreshRequest = nil
    }

    func shouldDrop(framePTS: CMTime, displayBounds: CGRect) -> Bool {
        lock.lock()
        let pending = uncovered
        let filterChangedAt = coveredAt
        lock.unlock()

        if CMTimeCompare(framePTS, filterChangedAt) < 0 { return true }
        guard !pending.isEmpty else { return false }
        guard Self.hasContentWindow(of: pending, in: windowList(), on: displayBounds) else { return false }
        requestRefreshIfDue()
        return true
    }

    /// Whether one of `pids` has a visible content window on the display. Status items and other
    /// system-level windows do not count: they show no app content, and a menu bar helper would
    /// otherwise stop capture for as long as it runs.
    static func hasContentWindow(of pids: Set<pid_t>, in windows: [AXScreenWindow], on displayBounds: CGRect) -> Bool {
        windows.contains { window in
            pids.contains(window.pid) && isContentWindow(window) && window.bounds.intersects(displayBounds)
        }
    }

    static func isContentWindow(_ window: AXScreenWindow) -> Bool {
        window.layer >= 0 && window.layer < AXWindowPlanner.maxContentLayer && window.alpha >= AXWindowPlanner.invisibleAlpha
    }

    private func requestRefreshIfDue() {
        let now = uptime()
        lock.lock()
        let isDue = lastRefreshRequest.map { now - $0 >= Self.refreshInterval } ?? true
        if isDue { lastRefreshRequest = now }
        lock.unlock()
        if isDue { onRefreshNeeded() }
    }

    static func liveWindowList() -> [AXScreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return AXScreenWindow.parse(info)
    }
}
