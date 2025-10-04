import Foundation

// Capture usage time tracker backed by SQLite (ts_usage_session table).
// Performs a one-time migration from the old UserDefaults JSON key (usage.sessions) if present.
final class UsageTracker {
    static let shared = UsageTracker()
    private init() {}

    private let lock = NSLock()
    private var currentSessionId: Int64?
    private let maxOpenSeconds: TimeInterval = 12 * 3600
    // If capture starts while DB is unavailable (e.g. vault locked), defer creating a session
    // until the vault is unlocked so usage time is not lost.
    private var pendingStartTime: TimeInterval?

    private func finalizeStaleOpenSessionsIfNeeded() {
        if !staleFinalized {
            DB.shared.finalizeStaleOpenUsageSessions(maxOpenSeconds: maxOpenSeconds, now: Date().timeIntervalSince1970)
            staleFinalized = true
        }
    }
    private var staleFinalized: Bool = false

    // MARK: - Public API
    func captureStarted() {
        finalizeStaleOpenSessionsIfNeeded()
        lock.lock(); defer { lock.unlock() }
        if currentSessionId != nil { return }
        let now = Date().timeIntervalSince1970
        if let id = try? DB.shared.beginUsageSession(start: now) {
            currentSessionId = id
            pendingStartTime = nil
        } else {
            // Likely DB locked (vault). Remember start time.
            pendingStartTime = now
        }
    }

    func captureStopped() {
        lock.lock(); defer { lock.unlock() }
        guard let id = currentSessionId else {
            // No active DB session; drop any pending start.
            pendingStartTime = nil
            return
        }
        let now = Date().timeIntervalSince1970
        try? DB.shared.endUsageSession(id: id, end: now)
        currentSessionId = nil
    }

    func appWillTerminate() { captureStopped() }

    func totalSeconds(now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        finalizeStaleOpenSessionsIfNeeded()
        return (try? DB.shared.totalUsageSeconds(now: now)) ?? 0
    }

    func secondsLast24h(now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        finalizeStaleOpenSessionsIfNeeded()
        let cutoff = now - 86400
        return (try? DB.shared.usageSecondsSince(cutoff: cutoff, now: now)) ?? 0
    }

    // Invoke when vault unlock completes to backfill any pending usage session.
    func onVaultUnlocked() {
        lock.lock(); defer { lock.unlock() }
        guard currentSessionId == nil, let start = pendingStartTime else { return }
        if let id = try? DB.shared.beginUsageSession(start: start) {
            currentSessionId = id
            pendingStartTime = nil
        }
    }
}
