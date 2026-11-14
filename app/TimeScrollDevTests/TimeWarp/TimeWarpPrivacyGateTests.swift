import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpPrivacyGateTests {
  private let chrome = PrivateBrowsingCatalog.profile(forBundleId: "com.google.Chrome")
  private let unverified = PrivateBrowsingCatalog.profiles.first { $0.verification == .unverified }

  private func decide(_ bundleId: String, excluded: Set<String> = [], isBrowser: Bool, profile: PrivateBrowsingProfile?,
                      verdict: PrivateWindowVerdict?) -> TimeWarpPrivacyGate.Decision {
    TimeWarpPrivacyGate.decision(bundleId: bundleId, excluded: excluded, isBrowser: isBrowser, profile: profile, verdict: verdict)
  }

  @Test func ordinaryAppsAreAllowed() {
    #expect(decide("com.apple.TextEdit", isBrowser: false, profile: nil, verdict: nil) == .allowed)
  }

  @Test func excludedAppsAreBlocked() {
    #expect(decide("com.apple.TextEdit", excluded: ["com.apple.TextEdit"], isBrowser: false, profile: nil, verdict: nil) == .blocked)
    #expect(decide("com.google.Chrome", excluded: ["com.google.Chrome"], isBrowser: true, profile: chrome, verdict: .normal) == .blocked)
  }

  @Test func testedBrowsersNeedANormalVerdict() {
    #expect(chrome?.verification == .liveTested)
    #expect(decide("com.google.Chrome", isBrowser: true, profile: chrome, verdict: .normal) == .allowed)
    for verdict: PrivateWindowVerdict? in [.privateWindow, .auxiliary, .undetermined, nil] {
      #expect(decide("com.google.Chrome", isBrowser: true, profile: chrome, verdict: verdict) == .blocked)
    }
  }

  @Test func untestedOrUnknownBrowsersAreBlocked() {
    #expect(decide("org.unknown.Browser", isBrowser: true, profile: nil, verdict: .normal) == .blocked)
    if let unverified, let bundleId = unverified.bundleIds.first {
      #expect(decide(bundleId, isBrowser: true, profile: unverified, verdict: .normal) == .blocked)
    }
  }
}
