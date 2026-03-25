import Foundation

public final class PreferencesService {
    public init() {}

    public var aiEmbeddingsEnabled: Bool {
        return (StoragePaths.sharedObject(forKey: "settings.aiEmbeddingsEnabled") != nil)
            ? StoragePaths.sharedBool(forKey: "settings.aiEmbeddingsEnabled")
            : false
    }

    // Expose the raw value to avoid coupling to SettingsStore type here.
    public var fuzzinessRaw: String {
        return StoragePaths.sharedString(forKey: "settings.fuzziness") ?? "low"
    }

    public var intelligentAccuracy: Bool {
        return (StoragePaths.sharedObject(forKey: "settings.intelligentAccuracy") != nil)
            ? StoragePaths.sharedBool(forKey: "settings.intelligentAccuracy")
            : true
    }
}
