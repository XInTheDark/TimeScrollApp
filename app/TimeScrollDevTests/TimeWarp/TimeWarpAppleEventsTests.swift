import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpAppleEventsTests {
  @Test func onlyAppsTimeWarpReadsAreOffered() {
    let offered = Set(TimeWarpAppleEvents.supportedBundleIds)
    #expect(offered == ["com.google.Chrome", "com.brave.Browser", "com.apple.Safari",
                        TimeWarpBrowserCatalog.finderBundleId, TimeWarpBrowserCatalog.iTermBundleId])
  }

  @Test func everyOfferedBrowserIsLiveTested() {
    for bundleId in TimeWarpAppleEvents.supportedBundleIds {
      guard let profile = PrivateBrowsingCatalog.profile(forBundleId: bundleId) else { continue }
      #expect(profile.verification == .liveTested, "\(bundleId)")
    }
  }
}
