import Foundation

/// The database operations `UsageTracker` needs.
protocol UsageSessionStore {
    func beginUsageSession(start: TimeInterval) throws -> Int64
    func endUsageSession(id: Int64, end: TimeInterval) throws
    @discardableResult
    func closeOrphanedUsageSessions(startedBefore launchTime: TimeInterval) -> Bool
}

extension DB: UsageSessionStore {}

// Capture usage time tracker backed by SQLite (ts_usage_session table).
// All database work runs on a private serial queue so callers on the main thread never
// block behind the database queue (which may be busy with maintenance or capture writes).
final class UsageTracker: @unchecked Sendable {
    static let shared = UsageTracker(store: DB.shared)

    private let store: UsageSessionStore
    /// Anything still open that started before this was left behind by an earlier run.
    private let launchTime: TimeInterval
    private let queue = DispatchQueue(label: "TimeScroll.UsageTracker", qos: .utility)
    private var currentSessionId: Int64?
    // If capture starts while DB is unavailable (e.g. vault locked), defer creating a session
    // until the vault is unlocked so usage time is not lost.
    private var pendingStartTime: TimeInterval?
    private var orphanedSessionsClosed: Bool = false
    // Capture is on, but the machine is asleep so nothing is being recorded.
    private var suspendedForSleep: Bool = false

    init(store: UsageSessionStore, launchTime: TimeInterval = Date().timeIntervalSince1970) {
        self.store = store
        self.launchTime = launchTime
    }

    // Must run on `queue`.
    private func closeOrphanedSessionsIfNeeded() {
        guard !orphanedSessionsClosed else { return }
        orphanedSessionsClosed = store.closeOrphanedUsageSessions(startedBefore: launchTime)
    }

    // Must run on `queue`.
    private func beginSession(at start: TimeInterval) {
        closeOrphanedSessionsIfNeeded()
        if currentSessionId != nil { return }
        if let id = try? store.beginUsageSession(start: start) {
            currentSessionId = id
            pendingStartTime = nil
        } else {
            // Likely DB locked (vault). Remember start time.
            pendingStartTime = start
        }
    }

    // MARK: - Public API
    func captureStarted(at now: TimeInterval = Date().timeIntervalSince1970) {
        queue.async { [self] in
            suspendedForSleep = false
            beginSession(at: now)
        }
    }

    func captureStopped(at now: TimeInterval = Date().timeIntervalSince1970) {
        queue.async { [self] in
            suspendedForSleep = false
            endCurrentSession(at: now)
        }
    }

    func appWillTerminate(at now: TimeInterval = Date().timeIntervalSince1970) {
        queue.sync {
            suspendedForSleep = false
            endCurrentSession(at: now)
        }
    }

    func systemWillSleep(at now: TimeInterval = Date().timeIntervalSince1970) {
        queue.async { [self] in
            guard currentSessionId != nil || pendingStartTime != nil else { return }
            endCurrentSession(at: now)
            suspendedForSleep = true
        }
    }

    func systemDidWake(at now: TimeInterval = Date().timeIntervalSince1970) {
        queue.async { [self] in
            guard suspendedForSleep else { return }
            suspendedForSleep = false
            beginSession(at: now)
        }
    }

    /// Blocks until sessions left open by an earlier run are closed, if the database is available.
    func closeOrphanedSessions() {
        queue.sync { closeOrphanedSessionsIfNeeded() }
    }

    // Invoke when vault unlock completes to backfill any pending usage session.
    func onVaultUnlocked() {
        queue.async { [self] in
            closeOrphanedSessionsIfNeeded()
            guard currentSessionId == nil, let start = pendingStartTime else { return }
            if let id = try? store.beginUsageSession(start: start) {
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
        try? store.endUsageSession(id: id, end: now)
        currentSessionId = nil
    }
}
