import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private init() {
        load()
    }
    private var isLoading: Bool = false

    enum OCRMode: String, CaseIterable, Identifiable { case fast, accurate; var id: String { rawValue } }
    enum Fuzziness: String, CaseIterable, Identifiable { case off, low, medium, high; var id: String { rawValue } }
    enum StorageFormat: String, CaseIterable, Identifiable { case hevc, heic, jpeg, png; var id: String { rawValue } }
    enum DisplayCaptureMode: String, CaseIterable, Identifiable { case first, all; var id: String { rawValue } }

    @Published var ocrMode: OCRMode = .accurate { didSet { if !isLoading { save() } } }
    @Published var captureMinInterval: Double = 5.0 { didSet { if !isLoading { save() } } }
    @Published var fuzziness: Fuzziness = .low { didSet { if !isLoading { save() } } }
    @Published var retentionDays: Int = 30 { didSet { if !isLoading { save() } } }
    @Published var showHighlights: Bool = true { didSet { if !isLoading { save() } } }
    @Published var debugMode: Bool = false { didSet { if !isLoading { save() } } }
    @Published var refreshOnNewSnapshot: Bool = true { didSet { if !isLoading { save() } } }

    // Storage & reduction settings
    @Published var storageFormat: StorageFormat = .heic { didSet { if !isLoading { save() } } }
    @Published var maxLongEdge: Int = 1600 { didSet { if !isLoading { save() } } }            // 0 = original
    @Published var lossyQuality: Double = 0.6 { didSet { if !isLoading { save() } } }         // 0.1...1.0
    @Published var dedupEnabled: Bool = true { didSet { if !isLoading { save() } } }
    @Published var dedupHammingThreshold: Int = 6 { didSet { if !isLoading { save() } } }     // 0..64
    @Published var adaptiveSampling: Bool = true { didSet { if !isLoading { save() } } }
    @Published var adaptiveMaxInterval: Double = 30.0 { didSet { if !isLoading { save() } } }  // seconds
    @Published var degradeAfterDays: Int = 7 { didSet { if !isLoading { save() } } }
    @Published var degradeMaxLongEdge: Int = 1200 { didSet { if !isLoading { save() } } }
    @Published var degradeQuality: Double = 0.5 { didSet { if !isLoading { save() } } }
    // Storage location (display only; bookmark lives in UserDefaults for background use)
    @Published var storageFolderPath: String = StoragePaths.displayPath() { didSet { if !isLoading { save() } } }
    // Backup (external) storage option and display path
    @Published var backupEnabled: Bool = false { didSet { if !isLoading { save() } } }
    @Published var backupFolderPath: String = StoragePaths.backupDisplayPath() { didSet { if !isLoading { save() } } }
    // Energy: keep captureScale
    @Published var captureScale: Double = 0.8 { didSet { if !isLoading { save() } } }  // 0.5...1.0
    // Displays: capture first or all
    @Published var captureDisplayMode: DisplayCaptureMode = .first { didSet { if !isLoading { save() } } }

    // App behavior
    @Published var startMinimized: Bool = false { didSet { if !isLoading { save() } } }
    // When false, hide dock icon if there is no visible window
    @Published var showDockIcon: Bool = true { didSet { if !isLoading { save() } } }
    // Auto-start capture when app launches
    @Published var startRecordingOnStart: Bool = true { didSet { if !isLoading { save() } } }

    // Search behavior
    // When enabled, search tolerates common OCR character confusions (e.g., i↔l↔1, o↔0, rn↔m).
    @Published var intelligentAccuracy: Bool = true { didSet { if !isLoading { save() } } }
    // AI (embedding) search settings
    @Published var aiEmbeddingsEnabled: Bool = false { didSet { if !isLoading { save() } } }
    // Remembers the toggle position in the search UI
    @Published var aiModeOn: Bool = true { didSet { if !isLoading { save() } } }
    // Similarity threshold (0..1)
    @Published var aiThreshold: Double = 0.30 { didSet { if !isLoading { save() } } }
    // Max candidates scored per query (performance knob)
    @Published var aiMaxCandidates: Int = 10000 { didSet { if !isLoading { save() } } }
    // Embedding provider selection
    @Published var embeddingProvider: String = "apple-nl" { didSet { if !isLoading { save() } } }

    // Privacy
    // List of bundle identifiers for which capture should be suppressed when frontmost
    @Published var blacklistBundleIds: [String] = [] { didSet { if !isLoading { save() } } }

    // Updates
    @Published var updateChannelBeta: Bool = false { didSet { if !isLoading { save() } } }
    @Published var enableAutoCheckUpdates: Bool = true { didSet { if !isLoading { save() } } }
    @Published var autoCheckIntervalHours: Int = 24 { didSet { if !isLoading { save() } } }
    @Published var autoDownloadInstallUpdates: Bool = true { didSet { if !isLoading { save() } } }

    // Security
    @Published var vaultEnabled: Bool = false { didSet { if !isLoading { save() } } }
    @Published var captureWhileLocked: Bool = true { didSet { if !isLoading { save() } } }
    @Published var autoLockInactivityMinutes: Int = 0 { didSet { if !isLoading { save() } } }
    @Published var autoLockOnSleep: Bool = false { didSet { if !isLoading { save() } } }

    private let defaults = UserDefaults.standard

    private func load() {
        logContext("load")
        isLoading = true
        if let raw = defaults.string(forKey: "settings.ocrMode"), let v = OCRMode(rawValue: raw) { ocrMode = v }
        let interval = defaults.double(forKey: "settings.captureMinInterval")
        if interval > 0 { captureMinInterval = interval }
        if let raw = defaults.string(forKey: "settings.fuzziness"), let v = Fuzziness(rawValue: raw) { fuzziness = v }
        let rd = defaults.integer(forKey: "settings.retentionDays")
        if rd > 0 { retentionDays = rd }
        if defaults.object(forKey: "settings.showHighlights") != nil {
            showHighlights = defaults.bool(forKey: "settings.showHighlights")
        }
        if defaults.object(forKey: "settings.debugMode") != nil {
            debugMode = defaults.bool(forKey: "settings.debugMode")
        }
        if defaults.object(forKey: "settings.refreshOnNewSnapshot") != nil {
            refreshOnNewSnapshot = defaults.bool(forKey: "settings.refreshOnNewSnapshot")
        }

        if let raw = defaults.string(forKey: "settings.storageFormat"), let f = StorageFormat(rawValue: raw) { storageFormat = f }
        if let p = defaults.string(forKey: StoragePaths.displayPathKey) { storageFolderPath = p }
        if defaults.object(forKey: "settings.backupEnabled") != nil { backupEnabled = defaults.bool(forKey: "settings.backupEnabled") }
        if let bp = defaults.string(forKey: StoragePaths.backupDisplayPathKey) { backupFolderPath = bp }
        let mle = defaults.integer(forKey: "settings.maxLongEdge"); if mle >= 0 { maxLongEdge = mle }
        let q = defaults.double(forKey: "settings.lossyQuality"); if q > 0 { lossyQuality = q }
        if defaults.object(forKey: "settings.dedupEnabled") != nil { dedupEnabled = defaults.bool(forKey: "settings.dedupEnabled") }
        let thr = defaults.integer(forKey: "settings.dedupHammingThreshold"); if thr > 0 { dedupHammingThreshold = thr }
        if defaults.object(forKey: "settings.adaptiveSampling") != nil { adaptiveSampling = defaults.bool(forKey: "settings.adaptiveSampling") }
        let maxInt = defaults.double(forKey: "settings.adaptiveMaxInterval"); if maxInt > 0 { adaptiveMaxInterval = maxInt }
        let dDays = defaults.integer(forKey: "settings.degradeAfterDays"); if dDays >= 0 { degradeAfterDays = dDays }
        let dEdge = defaults.integer(forKey: "settings.degradeMaxLongEdge"); if dEdge > 0 { degradeMaxLongEdge = dEdge }
        let dQ = defaults.double(forKey: "settings.degradeQuality"); if dQ > 0 { degradeQuality = dQ }

        // Load capture scale if present
        let capScale = defaults.double(forKey: "settings.captureScale"); if capScale > 0 { captureScale = capScale }
        if let raw = defaults.string(forKey: "settings.captureDisplayMode"), let v = DisplayCaptureMode(rawValue: raw) { captureDisplayMode = v }

        // App behavior
        if defaults.object(forKey: "settings.startMinimized") != nil { startMinimized = defaults.bool(forKey: "settings.startMinimized") }
        if defaults.object(forKey: "settings.showDockIcon") != nil { showDockIcon = defaults.bool(forKey: "settings.showDockIcon") }
        if defaults.object(forKey: "settings.startRecordingOnStart") != nil { startRecordingOnStart = defaults.bool(forKey: "settings.startRecordingOnStart") }

        // Privacy
        if let arr = defaults.array(forKey: "settings.blacklistBundleIds") as? [String] {
            blacklistBundleIds = arr
        }

        // Search behavior
        if defaults.object(forKey: "settings.intelligentAccuracy") != nil {
            intelligentAccuracy = defaults.bool(forKey: "settings.intelligentAccuracy")
        }
        // AI search
        if defaults.object(forKey: "settings.aiEmbeddingsEnabled") != nil {
            aiEmbeddingsEnabled = defaults.bool(forKey: "settings.aiEmbeddingsEnabled")
        }
        if defaults.object(forKey: "settings.aiModeOn") != nil {
            aiModeOn = defaults.bool(forKey: "settings.aiModeOn")
        }
        let aiThr = defaults.double(forKey: "settings.aiThreshold"); if aiThr > 0 { aiThreshold = min(1.0, max(0.0, aiThr)) }
        let aiMC = defaults.integer(forKey: "settings.aiMaxCandidates"); if aiMC > 0 { aiMaxCandidates = aiMC }
        if let provider = defaults.string(forKey: "settings.embeddingProvider") { embeddingProvider = provider }

        // Updates
        if defaults.object(forKey: "settings.updateChannelBeta") != nil {
            updateChannelBeta = defaults.bool(forKey: "settings.updateChannelBeta")
        }
        if defaults.object(forKey: "settings.enableAutoCheckUpdates") != nil {
            enableAutoCheckUpdates = defaults.bool(forKey: "settings.enableAutoCheckUpdates")
        }
        let hrs = defaults.integer(forKey: "settings.autoCheckIntervalHours")
        if hrs > 0 { autoCheckIntervalHours = hrs }
        if defaults.object(forKey: "settings.autoDownloadInstallUpdates") != nil {
            autoDownloadInstallUpdates = defaults.bool(forKey: "settings.autoDownloadInstallUpdates")
        }
    // Security
    if defaults.object(forKey: "settings.vaultEnabled") != nil { vaultEnabled = defaults.bool(forKey: "settings.vaultEnabled") }
    if defaults.object(forKey: "settings.captureWhileLocked") != nil { captureWhileLocked = defaults.bool(forKey: "settings.captureWhileLocked") }
    let minutes = defaults.integer(forKey: "settings.autoLockInactivityMinutes"); if minutes >= 0 { autoLockInactivityMinutes = minutes }
    if defaults.object(forKey: "settings.autoLockOnSleep") != nil { autoLockOnSleep = defaults.bool(forKey: "settings.autoLockOnSleep") }
        isLoading = false
        print("[Prefs] Loaded: ocr=\(ocrMode.rawValue) minInt=\(captureMinInterval) fmt=\(storageFormat.rawValue) maxEdge=\(maxLongEdge) quality=\(lossyQuality) backup=\(backupEnabled) startMin=\(startMinimized) dock=\(showDockIcon) autoRec=\(startRecordingOnStart)")
    }

    private func save() {
        print("[Prefs] Save invoked…")
        defaults.set(ocrMode.rawValue, forKey: "settings.ocrMode")
        defaults.set(captureMinInterval, forKey: "settings.captureMinInterval")
        defaults.set(fuzziness.rawValue, forKey: "settings.fuzziness")
        defaults.set(retentionDays, forKey: "settings.retentionDays")
        defaults.set(showHighlights, forKey: "settings.showHighlights")
        defaults.set(debugMode, forKey: "settings.debugMode")
        defaults.set(refreshOnNewSnapshot, forKey: "settings.refreshOnNewSnapshot")

        defaults.set(storageFormat.rawValue, forKey: "settings.storageFormat")
        defaults.set(maxLongEdge, forKey: "settings.maxLongEdge")
        defaults.set(lossyQuality, forKey: "settings.lossyQuality")
        defaults.set(dedupEnabled, forKey: "settings.dedupEnabled")
        defaults.set(dedupHammingThreshold, forKey: "settings.dedupHammingThreshold")
        defaults.set(adaptiveSampling, forKey: "settings.adaptiveSampling")
        defaults.set(adaptiveMaxInterval, forKey: "settings.adaptiveMaxInterval")
        defaults.set(degradeAfterDays, forKey: "settings.degradeAfterDays")
        defaults.set(degradeMaxLongEdge, forKey: "settings.degradeMaxLongEdge")
        defaults.set(degradeQuality, forKey: "settings.degradeQuality")

        // Save capture scale
        defaults.set(captureScale, forKey: "settings.captureScale")
        defaults.set(captureDisplayMode.rawValue, forKey: "settings.captureDisplayMode")

        // App behavior
        defaults.set(startMinimized, forKey: "settings.startMinimized")
        defaults.set(showDockIcon, forKey: "settings.showDockIcon")
        defaults.set(startRecordingOnStart, forKey: "settings.startRecordingOnStart")

        // Privacy
        defaults.set(blacklistBundleIds, forKey: "settings.blacklistBundleIds")

        // Updates
        defaults.set(updateChannelBeta, forKey: "settings.updateChannelBeta")
        defaults.set(enableAutoCheckUpdates, forKey: "settings.enableAutoCheckUpdates")
        defaults.set(autoCheckIntervalHours, forKey: "settings.autoCheckIntervalHours")
        defaults.set(autoDownloadInstallUpdates, forKey: "settings.autoDownloadInstallUpdates")
        // Search behavior
        defaults.set(intelligentAccuracy, forKey: "settings.intelligentAccuracy")
        // AI search
        defaults.set(aiEmbeddingsEnabled, forKey: "settings.aiEmbeddingsEnabled")
        defaults.set(aiModeOn, forKey: "settings.aiModeOn")
        defaults.set(aiThreshold, forKey: "settings.aiThreshold")
        defaults.set(aiMaxCandidates, forKey: "settings.aiMaxCandidates")
        defaults.set(embeddingProvider, forKey: "settings.embeddingProvider")
        // Storage location display path (bookmark handled via StoragePaths.setStorageFolder)
        defaults.set(storageFolderPath, forKey: StoragePaths.displayPathKey)
        // Backup settings
        defaults.set(backupEnabled, forKey: "settings.backupEnabled")
        defaults.set(backupFolderPath, forKey: StoragePaths.backupDisplayPathKey)
    // Security
    defaults.set(vaultEnabled, forKey: "settings.vaultEnabled")
    defaults.set(captureWhileLocked, forKey: "settings.captureWhileLocked")
    defaults.set(autoLockInactivityMinutes, forKey: "settings.autoLockInactivityMinutes")
    defaults.set(autoLockOnSleep, forKey: "settings.autoLockOnSleep")
        defaults.synchronize()
        if let bundleId = Bundle.main.bundleIdentifier, let dom = defaults.persistentDomain(forName: bundleId) {
            print("[Prefs] Domain(\(bundleId)) keys=\(dom.keys.count)")
        } else {
            print("[Prefs] No persistent domain for bundle")
        }
    }

    // Explicitly persist current values. Useful when views close.
    func flush() {
        save()
    }

    private func logContext(_ phase: String) {
        let bundleId = Bundle.main.bundleIdentifier ?? "(nil)"
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        let prefsPath = lib?.appendingPathComponent("Preferences/\(bundleId).plist").path ?? "(unknown)"
        let exists = FileManager.default.fileExists(atPath: prefsPath)
        print("[Prefs] \(phase) bundle=\(bundleId) prefsPath=\(prefsPath) exists=\(exists)")
    }
}
