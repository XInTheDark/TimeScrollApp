import Foundation

/// Apps excluded from capture out of the box. Each is added to the user's list once, so a user can
/// remove one for good and later versions can still add new ones.
enum DefaultExcludedApps {
    static let system = ["com.apple.loginwindow"]

    static let passwordManagers = [
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.bitwarden.desktop",
        "com.keepersecurity.passwordmanager",
        "com.nordsec.nordpass",
        "in.sinew.Enpass-Desktop",
        "in.sinew.Enpass-Desktop.App",
        "me.proton.pass.electron",
        "org.keepassxc.keepassxc",
        "org.keepassx.keepassxc",
        "com.hicknhacksoftware.MacPass",
        "com.SiberSystems.RoboForm",
        "com.sibersystems.RoboFormMac",
    ]

    static var all: [String] { system + passwordManagers }

    /// The list after onboarding. The defaults are only added or removed if the choice changed, so
    /// repeating onboarding does not bring back a default the user removed in Settings.
    static func applyingOnboardingChoice(list: [String], includeDefaults: Bool, wasIncludingDefaults: Bool,
                                         added: [String]) -> [String] {
        var newList = list
        if includeDefaults != wasIncludingDefaults {
            if includeDefaults {
                newList += all.filter { !newList.contains($0) }
            } else {
                let defaults = Set(all)
                newList.removeAll { defaults.contains($0) }
            }
        }
        for bundleId in added where !newList.contains(bundleId) {
            newList.append(bundleId)
        }
        return newList
    }

    /// Adds every default not seeded before, unless the user opted out of the defaults.
    /// Returns the updated list and seeded ids.
    static func seed(list: [String], alreadySeeded: [String], declined: Bool = false) -> (list: [String], seeded: [String]) {
        if declined { return (list, alreadySeeded) }
        var newList = list
        var newSeeded = alreadySeeded
        for bundleId in all where !alreadySeeded.contains(bundleId) {
            newSeeded.append(bundleId)
            if !newList.contains(bundleId) { newList.append(bundleId) }
        }
        return (newList, newSeeded)
    }

    /// The ids to show in Settings. A password manager that is not installed stays excluded in case
    /// it is installed later, but would only show up as a raw bundle id.
    static func visible(in list: [String], isInstalled: (String) -> Bool) -> [String] {
        let managers = Set(passwordManagers)
        return list.filter { !managers.contains($0) || isInstalled($0) }
    }
}
