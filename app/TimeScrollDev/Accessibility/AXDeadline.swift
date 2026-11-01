import Dispatch

/// Time budget of one window's extraction, on the uptime clock.
struct AXDeadline {
    let softNanos: UInt64
    let hardNanos: UInt64

    init(startNanos: UInt64 = AXDeadline.now(), limits: AXTextLimits) {
        softNanos = startNanos + UInt64(max(0, limits.softTimeBudgetMs)) * 1_000_000
        hardNanos = startNanos + UInt64(max(0, limits.hardTimeBudgetMs)) * 1_000_000
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func isSoftExpired(at now: UInt64 = AXDeadline.now()) -> Bool { now >= softNanos }

    /// Seconds left before the hard deadline, or nil once it has passed.
    func remainingSeconds(at now: UInt64 = AXDeadline.now()) -> Float? {
        guard now < hardNanos else { return nil }
        return Float(hardNanos - now) / 1_000_000_000
    }
}
