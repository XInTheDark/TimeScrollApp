import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacyPane(settings: settings)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            SecurityPane(settings: settings)
                .tabItem { Label("Security", systemImage: "lock") }
            SearchPane(settings: settings)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            MCPSettingsPane()
                .tabItem { Label("MCP", systemImage: "bolt.horizontal") }
            StoragePane(settings: settings)
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            UpdatesPane(settings: settings)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            StatsPane()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 380)
        .onDisappear { settings.flush() }
    }
}

private struct SecurityPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var availableOllamaModels: [String] = []
    @State private var loadingModels: Bool = false
    @ObservedObject var vault = VaultManager.shared
    @State private var showVaultOnboarding: Bool = false
    @State private var pendingEnableVault: Bool = false
    @State private var showVaultDisableSheet: Bool = false
    @State private var pendingDisableVault: Bool = false
    var body: some View {
        Form {
            Section(header: Text("Encrypted Vault")) {
                Toggle("Enable encrypted vault", isOn: Binding(get: { settings.vaultEnabled }, set: { newVal in
                    if newVal {
                        // Show onboarding/confirmation the first time (or if user hasn't opted out)
                        let seen = UserDefaults.standard.bool(forKey: "vault.onboardingShown")
                        if !seen {
                            pendingEnableVault = true
                            showVaultOnboarding = true
                            return
                        }
                        // Direct enable
                        settings.vaultEnabled = true
                        Task { @MainActor in VaultManager.shared.setVaultEnabled(true) }
                        return
                    } else {
                        // Intercept turning off to confirm. Keep toggle ON until confirmed.
                        if settings.vaultEnabled {
                            pendingDisableVault = true
                            showVaultDisableSheet = true
                            // Revert visual change for now
                            settings.vaultEnabled = true
                            return
                        }
                    }
                    // Fallback
                    settings.vaultEnabled = newVal
                    Task { @MainActor in VaultManager.shared.setVaultEnabled(newVal) }
                }))
                Toggle("Allow capture while locked", isOn: $settings.captureWhileLocked)
            }
            Section(header: Text("Auto-lock")) {
                Toggle("Lock on sleep/wake", isOn: $settings.autoLockOnSleep)
                LabeledContent("After inactivity") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.autoLockInactivityMinutes, formatter: Self.intFormatter)
                            .frame(width: 70)
                        Text("minutes").foregroundColor(.secondary)
                    }
                }
            }
            Section(header: Text("Controls")) {
                HStack(spacing: 12) {
                    Button("Unlock…") { Task { await vault.unlock(presentingWindow: NSApp.keyWindow) } }
                        .disabled(!settings.vaultEnabled || vault.isUnlocked)
                    Button("Lock") { vault.lock() }
                        .disabled(!settings.vaultEnabled || !vault.isUnlocked)
                }
                if settings.vaultEnabled && vault.queuedCount > 0 {
                    Text("Queued: \(vault.queuedCount)").font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showVaultOnboarding) {
            VaultOnboardingSheet(onCancel: {
                // Revert toggle
                settings.vaultEnabled = false
                pendingEnableVault = false
                showVaultOnboarding = false
            }, onContinue: { dontShowAgain in
                if dontShowAgain {
                    UserDefaults.standard.set(true, forKey: "vault.onboardingShown")
                }
                settings.vaultEnabled = true
                Task { @MainActor in VaultManager.shared.setVaultEnabled(true) }
                pendingEnableVault = false
                showVaultOnboarding = false
            })
        }
        .sheet(isPresented: $showVaultDisableSheet) {
            VaultDisableConfirmSheet(onCancel: {
                // Keep encryption ON
                pendingDisableVault = false
                showVaultDisableSheet = false
            }, onContinue: {
                // Turn off encryption and lock the vault immediately
                settings.vaultEnabled = false
                Task { @MainActor in VaultManager.shared.setVaultEnabled(false) }
                pendingDisableVault = false
                showVaultDisableSheet = false
            })
        }
    }

    private static var intFormatter: NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 0; f.maximum = 600; return f
    }
}

private struct VaultOnboardingSheet: View {
    var onCancel: () -> Void
    var onContinue: (_ dontShowAgain: Bool) -> Void
    @State private var dontShow: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 28))
                Text("Encrypted Vault (Beta)").font(.title3).bold()
            }
            Text("Before you enable encryption:")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text("This feature is in beta. Data may be lost, and there is no guarantee it is 100% secure. Keep backups if this data matters to you.")
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "cpu.fill").foregroundColor(.secondary)
                    Text("Encryption will increase resource usage due to encryption/decryption during capture, thumbnailing, and viewing.")
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("You can turn off encryption later.")
                }
            }
            Toggle("Don't show this again", isOn: $dontShow)
                .toggleStyle(.checkbox)
                .padding(.top, 6)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Enable Encryption") { onContinue(dontShow) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
    }
}

private struct VaultDisableConfirmSheet: View {
    var onCancel: () -> Void
    var onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundColor(.yellow)
                Text("Turn Off Encryption?").font(.title3).bold()
            }
            Text("If you turn off encryption:")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Label("New snapshots will be saved unencrypted.", systemImage: "doc")
                Label("Existing encrypted snapshots will remain encrypted on disk and will no longer be viewable. You can re‑enable encryption later to access those encrypted snapshots.", systemImage: "lock")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text("Data may be lost after disabling encryption. If the app breaks, please reset all data.")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Turn Off Encryption") { onContinue() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
    }
}


private struct GeneralPane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            Section(header: Text("App")) {
                Toggle("Start minimized (menu bar only)", isOn: $settings.startMinimized)
                Toggle("Start recording on launch", isOn: $settings.startRecordingOnStart)
                Toggle("Show Dock icon when no window", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { newVal in
                        let anyVisible = NSApplication.shared.windows.contains { $0.isVisible }
                        if !anyVisible {
                            NSApplication.shared.setActivationPolicy(newVal ? .regular : .accessory)
                        }
                    }
            }
            Section(header: Text("OCR")) {
                LabeledContent("Recognition mode") {
                    Picker("", selection: $settings.ocrMode) {
                        ForEach(SettingsStore.OCRMode.allCases) { m in
                            Text(m.rawValue.capitalized).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                Text("OCR is used for text search. With Fast mode, the results will probably be messy.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Capture")) {
                LabeledContent("Min interval") {
                    HStack {
                        Slider(value: Self.minIntervalIndexBinding(settings: settings), in: 0...Double(Self.minIntervalOptions.count - 1), step: 1)
                        Text(Self.formatInterval(settings.captureMinInterval))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent("Retention") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.retentionDays, formatter: Self.intFormatter)
                            .frame(width: 70)
                        Text("days").foregroundColor(.secondary)
                    }
                }

                LabeledContent("Capture scale") {
                    HStack {
                        Slider(value: $settings.captureScale, in: 0.5...1.0, step: 0.05)
                        Text(String(format: "%.0f%%", settings.captureScale * 100))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .onChange(of: settings.captureScale) { _ in
                    Task { @MainActor in
                        await AppState.shared.restartCaptureIfRunning()
                    }
                }
                LabeledContent("Displays") {
                    Picker("", selection: $settings.captureDisplayMode) {
                        ForEach(SettingsStore.DisplayCaptureMode.allCases) { m in
                            Text(m == .first ? "First display" : "All displays").tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                .onChange(of: settings.captureDisplayMode) { _ in
                    Task { @MainActor in
                        await AppState.shared.restartCaptureIfRunning()
                    }
                }
                .onChange(of: settings.captureMinInterval) { newVal in
                    if settings.adaptiveMaxInterval < newVal { settings.adaptiveMaxInterval = newVal }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 365
        return f
    }()

    private static let minIntervalOptions: [Double] = [
        0.5, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 15.0, 20.0, 30.0
    ]

    private static func indexForInterval(_ value: Double) -> Int {
        var bestIdx = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (i, v) in minIntervalOptions.enumerated() {
            let d = abs(v - value)
            if d < bestDelta {
                bestDelta = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    private static func minIntervalIndexBinding(settings: SettingsStore) -> Binding<Double> {
        Binding<Double>(
            get: { Double(indexForInterval(settings.captureMinInterval)) },
            set: { newVal in
                let idx = max(0, min(minIntervalOptions.count - 1, Int(newVal.rounded())))
                settings.captureMinInterval = minIntervalOptions[idx]
            }
        )
    }

    private static func formatInterval(_ value: Double) -> String {
        if value < 1.0 { return String(format: "%.1f s", value) }
        if value < 10.0 { return String(format: "%.1f s", value) }
        return String(format: "%.0f s", value)
    }
}

private struct SearchPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var isInstallingModel = false
    @State private var installError: String?
    @State private var availableOllamaModels: [String] = []
    @State private var loadingModels: Bool = false
    @State private var modelInstalled: Bool = false
    @State private var checkingModelInstall: Bool = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Fuzziness") {
                    Picker("", selection: $settings.fuzziness) {
                        ForEach(SettingsStore.Fuzziness.allCases) { f in
                            Text(f.rawValue.capitalized).tag(f)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
                Toggle("Show highlight boxes", isOn: $settings.showHighlights)
                Toggle("Intelligent accuracy improvement", isOn: $settings.intelligentAccuracy)
            } header: { Text("Search behavior") }
            Section {
                Toggle("Enable AI Mode", isOn: $settings.aiEmbeddingsEnabled)
                Text("AI mode uses on-device machine learning to improve search results. It slightly increases energy and disk usage.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                LabeledContent("Embedding provider") {
                    Picker("", selection: $settings.embeddingProvider) {
                        ForEach(EmbeddingService.Provider.allCases, id: \.rawValue) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 280)
                    .disabled(!settings.aiEmbeddingsEnabled)
                }

                if settings.embeddingProvider == "ollama" {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Model")
                            Spacer()
                        }
                        if loadingModels {
                            HStack { ProgressView(); Text("Discovering models…").font(.footnote).foregroundColor(.secondary) }
                        } else {
                            Picker("", selection: $settings.embeddingModel) {
                                ForEach(availableOllamaModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 280)
                        }

                        if !settings.embeddingModel.isEmpty {
                            if checkingModelInstall {
                                HStack {
                                    ProgressView()
                                    Text("Checking install status…").font(.footnote).foregroundColor(.secondary)
                                }
                            } else if modelInstalled {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text("Model installed").font(.footnote).foregroundColor(.secondary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .center, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                        Text("Model not installed").font(.footnote).foregroundColor(.secondary)
                                        Spacer()
                                        Button(isInstallingModel ? "Installing..." : "Install") {
                                            installOllamaModel()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isInstallingModel)
                                    }
                                    if let error = installError {
                                        Text(error).font(.footnote).foregroundColor(.red)
                                    }
                                }
                            }
                        }
                    }
                    .onAppear {
                        // Load available models lazily
                        if availableOllamaModels.isEmpty {
                            loadingModels = true
                            DispatchQueue.global().async {
                                let models = OllamaEmbeddingProvider.listModels()
                                DispatchQueue.main.async {
                                    availableOllamaModels = models.isEmpty ? ["snowflake-arctic-embed:33m"] : models
                                    loadingModels = false
                                }
                            }
                        }
                        refreshModelInstallState()
                    }
                    .onChange(of: settings.embeddingModel) { _ in
                        refreshModelInstallState()
                    }
                }

                Toggle("Default to AI mode in search", isOn: $settings.aiModeOn)
                    .disabled(!settings.aiEmbeddingsEnabled)
                LabeledContent("Similarity threshold") {
                    HStack {
                        Slider(value: $settings.aiThreshold, in: 0.0...0.8, step: 0.10)
                            .disabled(!settings.aiEmbeddingsEnabled)
                        Text(String(format: "%.2f", settings.aiThreshold))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Max candidates per query") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.aiMaxCandidates, formatter: Self.aiIntFormatter)
                            .frame(width: 90)
                            .disabled(!settings.aiEmbeddingsEnabled)
                        Text("rows").foregroundColor(.secondary)
                    }
                }
            } header: { Text("AI Search") }
        }
        .formStyle(.grouped)
        .onChange(of: settings.embeddingProvider) { _ in
            refreshModelInstallState()
        }
    }
}

extension SearchPane {
    private static var aiIntFormatter: NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 100; f.maximum = 100000; return f
    }

    private func installOllamaModel() {
        isInstallingModel = true
        installError = nil

        let model = settings.embeddingModel.isEmpty ? "snowflake-arctic-embed:33m" : settings.embeddingModel
        OllamaEmbeddingProvider.pullModel(model) { success, error in
            DispatchQueue.main.async {
                isInstallingModel = false
                if success {
                    refreshModelInstallState()
                } else {
                    installError = error ?? "Failed to install model"
                }
            }
        }
    }

    private func refreshModelInstallState() {
        guard settings.embeddingProvider == "ollama", !settings.embeddingModel.isEmpty else {
            checkingModelInstall = false
            modelInstalled = false
            return
        }
        checkingModelInstall = true
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = OllamaEmbeddingProvider.isModelInstalled(settings.embeddingModel)
            DispatchQueue.main.async {
                modelInstalled = installed
                checkingModelInstall = false
            }
        }
    }
}


private struct StatsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatsView()
        }
    }
}

private struct MCPSettingsPane: View {
    @AppStorage("settings.mcpEnabled") private var persistedEnabled: Bool = false
    @State private var showMigrationPrompt: Bool = false
    @State private var migrating: Bool = false
    @State private var migrationProgress: String = ""
    @State private var pendingEnableAfterConfirm: Bool = false

    var body: some View {
        MCPPane(
            mcpEnabled: toggleBinding,
            migrating: migrating,
            migrationProgress: migrationProgress
        )
        .sheet(isPresented: $showMigrationPrompt) {
            MCPMigrationConfirmSheet(onCancel: {
                pendingEnableAfterConfirm = false
                showMigrationPrompt = false
                persistedEnabled = false
            }, onContinue: {
                showMigrationPrompt = false
                beginLegacyMigration()
            })
            .frame(minWidth: 520)
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { persistedEnabled },
            set: { newVal in
                if newVal == persistedEnabled { return }
                if newVal {
                    handleEnableRequest()
                } else {
                    persistedEnabled = false
                }
            }
        )
    }

    private func handleEnableRequest() {
        if StoragePaths.needsLegacyMigrationForMCP() {
            pendingEnableAfterConfirm = true
            showMigrationPrompt = true
            return
        }
        persistedEnabled = true
    }

    private func beginLegacyMigration() {
        guard pendingEnableAfterConfirm else { return }
        pendingEnableAfterConfirm = false
        migrating = true
        migrationProgress = "Preparing…"
        let dest = StoragePaths.defaultRoot()
        Task { @MainActor in
            await StorageMigrationManager.shared.changeLocation(
                to: dest,
                moveExisting: true,
                deleteOld: true
            ) { msg in
                Task { @MainActor in migrationProgress = msg }
            }
            migrating = false
            migrationProgress = ""
            persistedEnabled = true
        }
    }
}

private struct MCPMigrationConfirmSheet: View {
    var onCancel: () -> Void
    var onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill.badge.checkmark").font(.system(size: 28))
                Text("Migrate Data for MCP").font(.title3).bold()
            }
            Text("Enabling MCP requires TimeScroll to perform a one-time data migration.")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Label("Snapshots, database, and vault files will be moved into a new folder.", systemImage: "arrow.right.doc.on.clipboard")
                Label("The original copy will be deleted after the move.", systemImage: "trash")
                Label("Capture will pause temporarily while the move runs.", systemImage: "pause")
            }
            Text("If you cancel, MCP will stay disabled and nothing will change.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Migrate and Enable") {
                    onContinue()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

private struct StoragePane: View {
    @ObservedObject var settings: SettingsStore
    @State private var showResetConfirm: Bool = false
    @State private var showChangeSheet: Bool = false
    @State private var pendingFolder: URL?
    @State private var moveExisting: Bool = true
    @State private var deleteOld: Bool = false
    @State private var migrating: Bool = false
    @State private var progress: String = ""
    // Backup chooser
    @State private var pendingBackupFolder: URL?
    var body: some View {
        Form {
            Section(header: Text("Location")) {
                LabeledContent("Storage folder") {
                    HStack(spacing: 8) {
                        Text(settings.storageFolderPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal") {
                            let url = URL(fileURLWithPath: StoragePaths.displayPath())
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Button("Change…") { chooseFolder() }
                        Button("Reset to Default") { resetToDefault() }
                    }
                }
                if migrating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(progress.isEmpty ? "Applying…" : progress)
                    }
                }

                Toggle("Backup older snapshots instead of deleting them", isOn: $settings.backupEnabled)
                    .help("Keeps recent data on this device. During pruning, older snapshots are moved to the backup folder instead of being deleted.")
                LabeledContent("Backup folder") {
                    HStack(spacing: 8) {
                        Text(settings.backupFolderPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal") {
                            let path = StoragePaths.backupDisplayPath()
                            guard path != "Not set" else { return }
                            let url = URL(fileURLWithPath: path)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Button("Choose…") { chooseBackupFolder() }
                        Button("Clear") {
                            StoragePaths.clearBackupFolder()
                            settings.backupFolderPath = StoragePaths.backupDisplayPath()
                        }
                    }
                }
            }
            Section(header: Text("Encoding")) {
                LabeledContent("Format") {
                    Picker("", selection: $settings.storageFormat) {
                        ForEach(SettingsStore.StorageFormat.allCases) { f in
                            Text(f.rawValue.uppercased()).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }

                LabeledContent("Max long edge") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.maxLongEdge) }, set: { settings.maxLongEdge = Int($0) }), in: 0...3000, step: 100)
                        Text(settings.maxLongEdge == 0 ? "Original" : "\(settings.maxLongEdge) px")
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                }

                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $settings.lossyQuality, in: 0.3...0.9, step: 0.05)
                        Text(String(format: "%.2f", settings.lossyQuality))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section(header: Text("Capture reduction")) {
                Toggle("Skip near-duplicates", isOn: $settings.dedupEnabled)

                LabeledContent("Dedup sensitivity") {
                    HStack {
                        Slider(
                            value: Binding(get: { Double(settings.dedupHammingThreshold) }, set: { settings.dedupHammingThreshold = Int($0) }),
                            in: 0...16,
                            step: 1
                        )
                        .help("Lower = more sensitive (keeps more snapshots). Higher = more aggressive dedup (keeps fewer snapshots).")
                        Text("\(settings.dedupHammingThreshold)")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                Toggle("Adaptive sampling", isOn: $settings.adaptiveSampling)

                LabeledContent("Max sampling interval") {
                    HStack {
                        Slider(value: $settings.adaptiveMaxInterval, in: 5.0...30.0, step: 5.0)
                            .help("Max time between frame-processing checks")
                        Text(String(format: "%.0f s", settings.adaptiveMaxInterval))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                Toggle("Refresh timeline on new snapshot", isOn: $settings.refreshOnNewSnapshot)
            }
            Section(header: Text("Aging & compaction")) {
                LabeledContent("Degrade after") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.degradeAfterDays, formatter: Self.intFormatter)
                            .frame(width: 70)
                        Text("days").foregroundColor(.secondary)
                    }
                }

                LabeledContent("Degrade size") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.degradeMaxLongEdge) }, set: { settings.degradeMaxLongEdge = Int($0) }), in: 600...2000, step: 100)
                        Text("\(settings.degradeMaxLongEdge) px")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                LabeledContent("Degrade quality") {
                    HStack {
                        Slider(value: $settings.degradeQuality, in: 0.3...0.8, step: 0.05)
                        Text(String(format: "%.2f", settings.degradeQuality))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section(header: Text("Delete")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permanently delete ALL app data, including database, snapshots, and settings. This cannot be undone.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button(role: .destructive) { showResetConfirm = true } label: { Text("Delete All Data and Reset") }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showChangeSheet) {
            StorageLocationChangeSheet(
                folder: pendingFolder,
                moveExisting: $moveExisting,
                deleteOld: $deleteOld,
                onCancel: { showChangeSheet = false },
                onApply: {
                    guard let dest = pendingFolder else { showChangeSheet = false; return }
                    showChangeSheet = false
                    migrating = true; progress = ""
                    Task { @MainActor in
                        await StorageMigrationManager.shared.changeLocation(to: dest, moveExisting: moveExisting, deleteOld: deleteOld) { msg in
                            Task { @MainActor in progress = msg }
                        }
                        // Update display path and UI
                        settings.storageFolderPath = StoragePaths.displayPath()
                        migrating = false; progress = ""
                    }
                }
            )
            .frame(minWidth: 520)
        }
        .sheet(isPresented: $showResetConfirm) {
            DataResetConfirmSheet(onCancel: {
                showResetConfirm = false
            }, onContinue: {
                showResetConfirm = false
                DataReset.wipeAllAppData()
            })
        }
    }

    private static var intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 365
        return f
    }()

}


 

private struct DataResetConfirmSheet: View {
    var onCancel: () -> Void
    var onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundColor(.yellow)
                Text("Delete All Data?").font(.title3).bold()
            }
            Text("This will permanently remove:")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Label("All snapshots and thumbnails", systemImage: "trash")
                Label("The local database and indexes", systemImage: "internaldrive")
                Label("All app settings and preferences", systemImage: "gearshape")
            }
            Text("The app will quit afterwards. This cannot be undone.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Delete and Reset") { onContinue() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
    }
}

private extension StoragePane {
    func chooseFolder() {
        let p = NSOpenPanel()
        p.title = "Choose Storage Folder"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        if p.runModal() == .OK, let url = p.url {
            pendingFolder = url
            moveExisting = true
            deleteOld = false
            showChangeSheet = true
        }
    }

    func resetToDefault() {
        pendingFolder = StoragePaths.defaultRoot()
        moveExisting = true
        deleteOld = false
        showChangeSheet = true
    }

    func chooseBackupFolder() {
        let p = NSOpenPanel()
        p.title = "Choose Backup Folder"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        if p.runModal() == .OK, let url = p.url {
            pendingBackupFolder = url
            StoragePaths.setBackupFolder(url)
            settings.backupFolderPath = StoragePaths.backupDisplayPath()
        }
    }
}

private struct StorageLocationChangeSheet: View {
    let folder: URL?
    @Binding var moveExisting: Bool
    @Binding var deleteOld: Bool
    var onCancel: () -> Void
    var onApply: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive").font(.system(size: 28))
                Text("Change Storage Location").font(.title3).bold()
            }
            if let u = folder {
                Text("New folder:")
                    .font(.headline)
                Text(u.path).lineLimit(2).truncationMode(.middle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Toggle("Move existing data to the new folder", isOn: $moveExisting)
                .toggleStyle(.checkbox)
            Toggle("Delete data from the previous folder after changing", isOn: $deleteOld)
                .toggleStyle(.checkbox)
                .help("Data in the old folder will be permanently removed after the change.")
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Apply Change") { onApply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}
