import Foundation

/// Which apps had a window read on one display in an unbroken run of captures, and since when.
/// Direct mode asks an app for its full accessibility tree only once the app has settled on screen,
/// so a window seen in passing (switching apps, a quick glance) does not make a Chromium or
/// Electron app build and keep that tree.
final class AXAppSightings {
    /// An app has settled once its windows were read in consecutive captures this long apart or more.
    static let settleTime: TimeInterval = 3

    private let lock = NSLock()
    private var since: [pid_t: TimeInterval] = [:]

    /// Records the apps read in this capture and returns those that have settled.
    func record(_ pids: Set<pid_t>, now: TimeInterval) -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        var next: [pid_t: TimeInterval] = [:]
        var settled: Set<pid_t> = []
        for pid in pids {
            let start = since[pid] ?? now
            next[pid] = start
            if now - start >= Self.settleTime { settled.insert(pid) }
        }
        since = next
        return settled
    }
}
