import Foundation

/// Bookkeeping for apps whose `AXManualAccessibility` flag TimeScroll turned on: when each was last
/// read, and which apps it must leave alone (flag unsupported, or already on before TimeScroll).
struct AXLeaseTable {
    private(set) var lastUsed: [pid_t: TimeInterval] = [:]
    private(set) var leftAlone: Set<pid_t> = []

    /// Whether the app still needs a decision (turn the flag on, or leave it alone).
    func isUndecided(_ pid: pid_t) -> Bool { lastUsed[pid] == nil && !leftAlone.contains(pid) }

    mutating func lease(_ pid: pid_t, now: TimeInterval) { lastUsed[pid] = now }
    mutating func leaveAlone(_ pid: pid_t) { leftAlone.insert(pid) }

    /// Marks leased apps as read now; apps not leased are ignored.
    mutating func touch(_ pids: some Sequence<pid_t>, now: TimeInterval) {
        for pid in pids where lastUsed[pid] != nil { lastUsed[pid] = now }
    }

    /// Ends and returns the leases unused for `idle` seconds.
    mutating func expire(now: TimeInterval, idle: TimeInterval) -> [pid_t] {
        let expired = lastUsed.filter { now - $0.value >= idle }.map(\.key)
        for pid in expired { lastUsed[pid] = nil }
        return expired.sorted()
    }

    /// Ends and returns every lease, and forgets which apps were left alone.
    mutating func endAll() -> [pid_t] {
        let all = lastUsed.keys.sorted()
        lastUsed.removeAll()
        leftAlone.removeAll()
        return all
    }

    /// Forgets left-alone apps that are no longer on screen, so they are checked again next time.
    mutating func forgetLeftAlone(except pids: Set<pid_t>) {
        leftAlone.formIntersection(pids)
    }
}
