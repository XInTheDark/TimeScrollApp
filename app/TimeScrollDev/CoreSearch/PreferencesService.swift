import Foundation

public final class PreferencesService {
    private let d = UserDefaults(suiteName: StoragePaths.appGroupID) ?? .standard

    public init() {}

    public var aiEmbeddingsEnabled: Bool {
        return (d.object(forKey: "settings.aiEmbeddingsEnabled") != nil) ? d.bool(forKey: "settings.aiEmbeddingsEnabled") : false
    }

    // Expose the raw value to avoid coupling to SettingsStore type here.
    public var fuzzinessRaw: String {
        return d.string(forKey: "settings.fuzziness") ?? "low"
    }

    public var intelligentAccuracy: Bool {
        return (d.object(forKey: "settings.intelligentAccuracy") != nil) ? d.bool(forKey: "settings.intelligentAccuracy") : true
    }
}
