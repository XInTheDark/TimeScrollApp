import Foundation
import Testing
@testable import TimeScroll

/// Time Warp is on by default, and the setup choice is stored either way. Uses its own defaults
/// suite so the user's settings are never touched.
@Suite struct TimeWarpSettingsTests {
  private func freshDefaults() -> UserDefaults {
    let name = "TimeWarpSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func onWhenNeverSet() {
    #expect(TimeWarpSettings.isEnabled(freshDefaults()))
  }

  @Test func followsStoredValue() {
    let defaults = freshDefaults()
    defaults.set(false, forKey: TimeWarpSettings.enabledKey)
    #expect(!TimeWarpSettings.isEnabled(defaults))
    defaults.set(true, forKey: TimeWarpSettings.enabledKey)
    #expect(TimeWarpSettings.isEnabled(defaults))
  }

  @Test func turningOffDuringSetupIsStored() {
    let defaults = freshDefaults()
    TimeWarpOnboardingCard.apply(false, defaults: defaults)
    #expect(defaults.object(forKey: TimeWarpSettings.enabledKey) != nil)
    #expect(!TimeWarpSettings.isEnabled(defaults))
  }

  @Test func leavingOnDuringSetupKeepsItOn() {
    let defaults = freshDefaults()
    TimeWarpOnboardingCard.apply(true, defaults: defaults)
    #expect(TimeWarpSettings.isEnabled(defaults))
    TimeWarpOnboardingCard.apply(false, defaults: defaults)
    TimeWarpOnboardingCard.apply(true, defaults: defaults)
    #expect(TimeWarpSettings.isEnabled(defaults))
  }
}
