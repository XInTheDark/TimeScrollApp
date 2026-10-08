import Foundation

extension FrameOutput {
    /// Wait after a switch before capturing, so window ordering and Space/full-screen
    /// transitions finish first. A newer switch restarts the wait, which also debounces Cmd-Tab cycling.
    static let appSwitchSettleDelay: TimeInterval = 0.5
    /// In "capture only after changes" mode, how long capture stays active after a switch settles.
    static let appSwitchCaptureWindow: TimeInterval = 10.0

    enum AppSwitchGate {
        /// Evaluate the frame with the normal cadence gate.
        case normal
        /// Evaluate the frame now, bypassing the cadence gate.
        case captureNow
        /// Drop the frame.
        case skip
    }

    /// Called on the stream's sample handler queue after the frontmost app changes.
    /// Sampling returns to the base interval so frames arrive promptly once the switch settles.
    func noteAppSwitch() {
        let now = ProcessInfo.processInfo.systemUptime
        appSwitchSettlesAt = now + Self.appSwitchSettleDelay
        appSwitchWindowEndsAt = now + Self.appSwitchSettleDelay + Self.appSwitchCaptureWindow
        stableCount = 0
        currentInterval = baseInterval
        reportProbeIntervalIfNeeded(force: true)
    }

    /// Decides how app-switch capture affects the frame arriving now. The frontmost-context
    /// check in `isNearDuplicate` keeps the post-switch frame unless the screen is unchanged.
    func appSwitchGate(mode: SettingsStore.AppSwitchCaptureMode) -> AppSwitchGate {
        let now = ProcessInfo.processInfo.systemUptime
        if let settlesAt = appSwitchSettlesAt {
            if mode == .off {
                appSwitchSettlesAt = nil
            } else if now < settlesAt {
                return .skip
            } else {
                appSwitchSettlesAt = nil
                return .captureNow
            }
        }
        if mode == .afterSwitchOnly && now >= appSwitchWindowEndsAt {
            reportProbeIntervalIfNeeded()
            return .skip
        }
        return .normal
    }

    /// True while "capture only after changes" is idle between windows, so frames can arrive slowly.
    var isIdleBetweenAppSwitchWindows: Bool {
        SettingsStore.AppSwitchCaptureMode.current() == .afterSwitchOnly
            && appSwitchSettlesAt == nil
            && ProcessInfo.processInfo.systemUptime >= appSwitchWindowEndsAt
    }
}
