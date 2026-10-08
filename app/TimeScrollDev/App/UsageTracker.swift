import Foundation

// Capture usage time tracker backed by SQLite (ts_usage_session table).
// All database work runs on a private serial queue so callers on the main thread never
// block behind the database queue (which may be busy with maintenance or capture writes).
final class UsageTracker {
    static let shared = UsageTracker()
    private init() {}

    private let queue = DispatchQueue(label: "TimeScroll.UsageTracker", qos: .utility)
    private var currentSessionId: Int64?
    // If capture starts while DB is unavailable (e.g. vault locked), defer creating a session
    // until the vault is unlocked so usage time is not lost.
    private var pendingStartTime: TimeInterval?
    private var orphanedSessionsClosed: Bool = false

    // Must run on `queue`.
    private func closeOrphanedSessionsIfNeeded() {
        if !orphanedSessionsClosed {
            // Close ALL open sessions from previous runs to prevent usage time inflation.
            // Sessions left open (e.g., from crashes or force quits) would otherwise count
            // time from their start all the way to now, even if the app wasn't running.
            DB.shared.closeAllOpenUsageSessions()
            orphanedSessionsClosed = true
        }
    }

    // MARK: - Public API
    func captureStarted() {
        let now = Date().timeIntervalSince1970
        queue.async { [self] in
            closeOrphanedSessionsIfNeeded()
            if currentSessionId != nil { return }
            if let id = try? DB.shared.beginUsageSession(start: now) {
                currentSessionId = id
                pendingStartTime = nil
            } else {
                // Likely DB locked (vault). Remember start time.
                pendingStartTime = now
            }
        }
    }

    func captureStopped() {
        let now = Date().timeIntervalSince1970
        queue.async { [self] in
            endCurrentSession(at: now)
        }
    }

    func appWillTerminate() {
        let now = Date().timeIntervalSince1970
        queue.sync { endCurrentSession(at: now) }
    }

    func totalSeconds(now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        queue.sync { closeOrphanedSessionsIfNeeded() }
        return (try? DB.shared.totalUsageSeconds(now: now)) ?? 0
    }

    func secondsLast24h(now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        queue.sync { closeOrphanedSessionsIfNeeded() }
        let cutoff = now - 86400
        return (try? DB.shared.usageSecondsSince(cutoff: cutoff, now: now)) ?? 0
    }

    // Invoke when vault unlock completes to backfill any pending usage session.
    func onVaultUnlocked() {
        queue.async { [self] in
            guard currentSessionId == nil, let start = pendingStartTime else { return }
            if let id = try? DB.shared.beginUsageSession(start: start) {
                currentSessionId = id
                pendingStartTime = nil
            }
        }
    }

    // Must run on `queue`.
    private func endCurrentSession(at now: TimeInterval) {
        guard let id = currentSessionId else {
            // No active DB session; drop any pending start.
            pendingStartTime = nil
            return
        }
        try? DB.shared.endUsageSession(id: id, end: now)
        currentSessionId = nil
    }
}
