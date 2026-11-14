import Foundation

/// Saves the Time Warp sheet's choices so the next sheet, even after a relaunch, starts with them.
struct TimeWarpChoicesStore {
  static let scopeKey = "timeWarp.sheet.scope"
  static let checkedGroupsKey = "timeWarp.sheet.checkedGroups"
  static let minimumMinutesKey = "timeWarp.sheet.minimumMinutes"
  static let newWindowKey = "timeWarp.sheet.opensInNewWindow"
  static let lookbackKey = "timeWarp.sheet.lookback"
  static let skipsOpenKey = "timeWarp.sheet.skipsOpenItems"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> TimeWarpChoices {
    var choices = TimeWarpChoices()
    if let raw = defaults.string(forKey: Self.scopeKey), let scope = TimeWarpScope(rawValue: raw) { choices.scope = scope }
    if let groups = defaults.array(forKey: Self.checkedGroupsKey) as? [String] {
      choices.checkedGroups = Set(groups.compactMap(TimeWarpGroup.init(rawValue:)))
    }
    if defaults.object(forKey: Self.minimumMinutesKey) != nil {
      let minutes = defaults.integer(forKey: Self.minimumMinutesKey)
      if TimeWarpChoices.minimumOptions.contains(minutes) { choices.minimumMinutes = minutes }
    }
    choices.opensInNewWindow = defaults.bool(forKey: Self.newWindowKey)
    if defaults.object(forKey: Self.skipsOpenKey) != nil { choices.skipsOpenItems = defaults.bool(forKey: Self.skipsOpenKey) }
    if let raw = defaults.string(forKey: Self.lookbackKey), let lookback = TimeWarpLookback(rawValue: raw) { choices.lookback = lookback }
    return choices
  }

  func save(_ choices: TimeWarpChoices) {
    defaults.set(choices.scope.rawValue, forKey: Self.scopeKey)
    defaults.set(choices.checkedGroups.map(\.rawValue).sorted(), forKey: Self.checkedGroupsKey)
    defaults.set(choices.minimumMinutes, forKey: Self.minimumMinutesKey)
    defaults.set(choices.opensInNewWindow, forKey: Self.newWindowKey)
    defaults.set(choices.lookback.rawValue, forKey: Self.lookbackKey)
    defaults.set(choices.skipsOpenItems, forKey: Self.skipsOpenKey)
  }
}
