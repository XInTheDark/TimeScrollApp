#if DEBUG
import Foundation
import Testing
@testable import TimeScroll

struct DemoModeTests {
  private let bundleId = "com.muzhen.TimeScroll.marketing"
  private let fakeHome = "/tmp/fake-home"
  private var environment: [String: String] {
    ["TIMESCROLL_DEMO_SCENE": "timeline", "CFFIXED_USER_HOME": fakeHome]
  }

  @Test func turnsOnOnlyWithMarketingBundleSceneAndFakeHome() {
    #expect(DemoMode.isAllowed(bundleId: bundleId, environment: environment, home: fakeHome))
  }

  @Test func normalBuildsNeverTurnOn() {
    #expect(!DemoMode.isAllowed(bundleId: "com.muzhen.TimeScroll", environment: environment, home: fakeHome))
    #expect(!DemoMode.isAllowed(bundleId: nil, environment: environment, home: fakeHome))
  }

  @Test func needsASceneAndAFakeHome() {
    #expect(!DemoMode.isAllowed(bundleId: bundleId, environment: ["CFFIXED_USER_HOME": fakeHome], home: fakeHome))
    #expect(!DemoMode.isAllowed(bundleId: bundleId, environment: ["TIMESCROLL_DEMO_SCENE": "timeline"], home: fakeHome))
    #expect(!DemoMode.isAllowed(bundleId: bundleId, environment: ["TIMESCROLL_DEMO_SCENE": "timeline", "CFFIXED_USER_HOME": ""], home: ""))
  }

  @Test func refusesWhenTheFakeHomeDidNotTakeEffect() {
    #expect(!DemoMode.isAllowed(bundleId: bundleId, environment: environment, home: "/Users/someone"))
  }

  @Test func theTestHostItselfIsNotInDemoMode() {
    #expect(!DemoMode.isActive)
  }
}
#endif
