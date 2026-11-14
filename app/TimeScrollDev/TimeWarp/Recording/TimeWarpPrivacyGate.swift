import Foundation

/// Whether a window's context may be recorded. Fails closed: a browser window is recorded only when
/// its browser's private-window detection was tested on real windows and this window was positively
/// classified normal. Excluded apps are never recorded.
enum TimeWarpPrivacyGate {
  enum Decision: Equatable {
    case allowed
    /// Recording must stop: an excluded app, a private window, or a window that could not be classified.
    case blocked
  }

  static func decision(bundleId: String, excluded: Set<String>, isBrowser: Bool,
                       profile: PrivateBrowsingProfile?, verdict: PrivateWindowVerdict?) -> Decision {
    guard !excluded.contains(bundleId) else { return .blocked }
    guard isBrowser || profile != nil else { return .allowed }
    guard let profile, profile.verification == .liveTested, verdict == .normal else { return .blocked }
    return .allowed
  }
}
