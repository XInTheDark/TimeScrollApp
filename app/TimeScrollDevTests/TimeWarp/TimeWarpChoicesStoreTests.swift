import Foundation
import Testing
@testable import TimeScroll

/// Uses its own defaults suite, never the app's.
final class TimeWarpChoicesStoreTests {
  private let suiteName = "TimeWarpChoicesStoreTests-\(UUID().uuidString)"
  private let defaults: UserDefaults

  init() {
    defaults = UserDefaults(suiteName: suiteName)!
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test func freshStoreGivesDefaults() {
    #expect(TimeWarpChoicesStore(defaults: defaults).load() == TimeWarpChoices())
  }

  @Test func choicesRoundTrip() {
    let store = TimeWarpChoicesStore(defaults: defaults)
    let choices = TimeWarpChoices(scope: .everythingOpen, checkedGroups: [.folders, .apps], minimumMinutes: 15, opensInNewWindow: true)
    store.save(choices)
    #expect(TimeWarpChoicesStore(defaults: defaults).load() == choices)
  }

  @Test func noCheckedGroupsIsRemembered() {
    let store = TimeWarpChoicesStore(defaults: defaults)
    store.save(TimeWarpChoices(checkedGroups: []))
    #expect(store.load().checkedGroups.isEmpty)
  }

  @Test func unknownValuesFallBack() {
    defaults.set("sideways", forKey: TimeWarpChoicesStore.scopeKey)
    defaults.set(["pages", "bogus"], forKey: TimeWarpChoicesStore.checkedGroupsKey)
    defaults.set(7, forKey: TimeWarpChoicesStore.minimumMinutesKey)
    let choices = TimeWarpChoicesStore(defaults: defaults).load()
    #expect(choices.scope == .visited)
    #expect(choices.checkedGroups == [.pages])
    #expect(choices.minimumMinutes == 1)
  }

  @Test func neverTouchesStandardDefaults() {
    let before = UserDefaults.standard.object(forKey: TimeWarpChoicesStore.scopeKey) as? String
    TimeWarpChoicesStore(defaults: defaults).save(TimeWarpChoices(scope: .everythingOpen))
    #expect(UserDefaults.standard.object(forKey: TimeWarpChoicesStore.scopeKey) as? String == before)
  }

  @Test func lookbackRoundTripsAndDefaultsToTheSession() {
    let store = TimeWarpChoicesStore(defaults: defaults)
    #expect(store.load().lookback == .session)
    for lookback in TimeWarpLookback.allCases {
      store.save(TimeWarpChoices(lookback: lookback))
      #expect(store.load().lookback == lookback)
    }
    defaults.set("forever", forKey: TimeWarpChoicesStore.lookbackKey)
    #expect(store.load().lookback == .session)
  }

  @Test func skippingOpenItemsDefaultsOnAndRoundTrips() {
    let store = TimeWarpChoicesStore(defaults: defaults)
    #expect(store.load().skipsOpenItems)
    store.save(TimeWarpChoices(skipsOpenItems: false))
    #expect(!store.load().skipsOpenItems)
    store.save(TimeWarpChoices(skipsOpenItems: true))
    #expect(store.load().skipsOpenItems)
  }
}
