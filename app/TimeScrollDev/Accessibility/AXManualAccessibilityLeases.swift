import AppKit
import ApplicationServices

/// Chromium and Electron apps build their accessibility tree only once an assistive app sets
/// `AXManualAccessibility`, and keep it (and its CPU and memory cost) until the flag is cleared.
/// TimeScroll turns the flag on only for apps that have settled on screen (`AXAppSightings`) and
/// that it is about to read, and clears it again when none of an app's windows has been read for
/// `idleTimeout` (a window that stays covered does not count), when Direct mode or capture stops,
/// and when TimeScroll quits. It never clears a flag that was on before it, or while VoiceOver is running.
/// `AXEnhancedUserInterface` is never touched: it changes other apps' rendering and window behavior.
final class AXManualAccessibilityLeases {
    static let shared = AXManualAccessibilityLeases()
    static let idleTimeout: TimeInterval = 10 * 60

    private static let attribute = "AXManualAccessibility" as CFString
    private static let ipcTimeout: Float = 0.1

    private let lock = NSLock()
    private var table = AXLeaseTable()

    /// Call before reading the app. Turns the flag on for `pid` once it has `settled` on screen,
    /// unless that was already decided. Returns whether the app's tree is complete enough to cache
    /// what is read now: not while undecided, nor right after the flag went on, as Chromium builds
    /// the tree asynchronously.
    func acquire(_ pid: pid_t, app: AXUIElement, settled: Bool, now: TimeInterval, debug: Bool) -> Bool {
        lock.lock()
        let undecided = table.isUndecided(pid)
        lock.unlock()
        guard undecided else { return true }
        guard settled else { return false }

        AXUIElementSetMessagingTimeout(app, Self.ipcTimeout)
        var current: CFTypeRef?
        let alreadyOn = AXUIElementCopyAttributeValue(app, Self.attribute, &current) == .success && (current as? Bool) == true
        let leased = !alreadyOn && AXUIElementSetAttributeValue(app, Self.attribute, kCFBooleanTrue) == .success
        if debug { print("[AX] pid=\(pid) AXManualAccessibility alreadyOn=\(alreadyOn) leased=\(leased)") }

        lock.lock()
        if leased { table.lease(pid, now: now) } else { table.leaveAlone(pid) }
        lock.unlock()
        return !leased
    }

    /// Keeps the leases of apps with a window `read` on a display, and ends those unused for
    /// `idleTimeout`. Apps with no window `onScreen` are checked again next time they are read.
    func refresh(read: Set<pid_t>, onScreen: Set<pid_t>, now: TimeInterval) {
        lock.lock()
        table.touch(read, now: now)
        let expired = table.expire(now: now, idle: Self.idleTimeout)
        table.forgetLeftAlone(except: onScreen)
        lock.unlock()
        restore(expired)
    }

    /// Clears the flag on every app TimeScroll turned it on for.
    func releaseAll() {
        lock.lock()
        let all = table.endAll()
        lock.unlock()
        restore(all)
    }

    /// `releaseAll` off the calling thread, for main-thread callers that need not wait.
    func releaseAllInBackground() {
        DispatchQueue.global(qos: .utility).async { self.releaseAll() }
    }

    private func restore(_ pids: [pid_t]) {
        guard !pids.isEmpty, !NSWorkspace.shared.isVoiceOverEnabled else { return }
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.ipcTimeout)
            _ = AXUIElementSetAttributeValue(app, Self.attribute, kCFBooleanFalse)
        }
    }
}
