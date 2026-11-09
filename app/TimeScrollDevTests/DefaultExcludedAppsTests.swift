import Testing
@testable import TimeScroll

@Suite struct DefaultExcludedAppsTests {
  @Test func freshInstallGetsEveryDefault() {
    let result = DefaultExcludedApps.seed(list: [], alreadySeeded: [])
    #expect(result.list == DefaultExcludedApps.all)
    #expect(result.seeded == DefaultExcludedApps.all)
  }

  @Test func userEntriesKeepTheirPlaceAndAreNotDuplicated() {
    let result = DefaultExcludedApps.seed(list: ["com.example.app", "com.bitwarden.desktop"], alreadySeeded: [])
    #expect(Array(result.list.prefix(2)) == ["com.example.app", "com.bitwarden.desktop"])
    #expect(result.list.filter { $0 == "com.bitwarden.desktop" }.count == 1)
  }

  @Test func earlierMigrationDoesNotBringBackRemovedLoginWindow() {
    let result = DefaultExcludedApps.seed(list: [], alreadySeeded: DefaultExcludedApps.system)
    #expect(!result.list.contains("com.apple.loginwindow"))
    #expect(result.list == DefaultExcludedApps.passwordManagers)
  }

  @Test func removedDefaultStaysRemoved() {
    let first = DefaultExcludedApps.seed(list: [], alreadySeeded: [])
    let afterRemoval = first.list.filter { $0 != "com.apple.Passwords" }
    let second = DefaultExcludedApps.seed(list: afterRemoval, alreadySeeded: first.seeded)
    #expect(second.list == afterRemoval)
    #expect(second.seeded == first.seeded)
  }

  @Test func defaultAddedLaterReachesExistingInstalls() {
    let seededEarlier = DefaultExcludedApps.all.filter { $0 != "com.apple.Passwords" }
    let result = DefaultExcludedApps.seed(list: ["com.example.app"], alreadySeeded: seededEarlier)
    #expect(result.list == ["com.example.app", "com.apple.Passwords"])
    #expect(Set(result.seeded) == Set(DefaultExcludedApps.all))
  }

  @Test func optingOutOnAFreshInstallLeavesAnEmptyList() {
    let seeded = DefaultExcludedApps.seed(list: [], alreadySeeded: [])
    let list = DefaultExcludedApps.applyingOnboardingChoice(
      list: seeded.list, includeDefaults: false, wasIncludingDefaults: true, added: [])
    #expect(list.isEmpty)
  }

  @Test func optingOutKeepsAppsTheUserChose() {
    let list = DefaultExcludedApps.applyingOnboardingChoice(
      list: DefaultExcludedApps.all + ["com.example.mine"], includeDefaults: false, wasIncludingDefaults: true,
      added: ["com.example.added", "com.bitwarden.desktop"])
    #expect(list == ["com.example.mine", "com.example.added", "com.bitwarden.desktop"])
  }

  @Test func optingOutSurvivesLaterSeeding() {
    let result = DefaultExcludedApps.seed(list: [], alreadySeeded: DefaultExcludedApps.all.dropLast().map { $0 }, declined: true)
    #expect(result.list.isEmpty)
    #expect(result.seeded.count == DefaultExcludedApps.all.count - 1)
  }

  @Test func optingBackInRestoresEveryDefaultOnce() {
    let list = DefaultExcludedApps.applyingOnboardingChoice(
      list: ["com.example.mine", "com.bitwarden.desktop"], includeDefaults: true, wasIncludingDefaults: false, added: [])
    #expect(Set(list) == Set(DefaultExcludedApps.all + ["com.example.mine"]))
    #expect(Set(list).count == list.count)
  }

  @Test func repeatingOnboardingUnchangedKeepsARemovedDefaultRemoved() {
    let removed = DefaultExcludedApps.all.filter { $0 != "com.apple.Passwords" }
    let list = DefaultExcludedApps.applyingOnboardingChoice(
      list: removed, includeDefaults: true, wasIncludingDefaults: true, added: [])
    #expect(list == removed)
  }

  @Test func addedAppsAreNotDuplicated() {
    let list = DefaultExcludedApps.applyingOnboardingChoice(
      list: ["com.example.mine"], includeDefaults: true, wasIncludingDefaults: true, added: ["com.example.mine", "com.example.new"])
    #expect(list == ["com.example.mine", "com.example.new"])
  }

  @Test func defaultsHaveNoDuplicates() {
    #expect(Set(DefaultExcludedApps.all).count == DefaultExcludedApps.all.count)
  }

  @Test func onlyUninstalledPasswordManagersAreHidden() {
    let list = ["com.example.notinstalled", "com.apple.loginwindow", "com.bitwarden.desktop", "com.1password.1password"]
    let visible = DefaultExcludedApps.visible(in: list) { $0 == "com.bitwarden.desktop" }
    #expect(visible == ["com.example.notinstalled", "com.apple.loginwindow", "com.bitwarden.desktop"])
  }

  @Test func emptyListStaysEmpty() {
    #expect(DefaultExcludedApps.visible(in: []) { _ in true }.isEmpty)
  }
}
