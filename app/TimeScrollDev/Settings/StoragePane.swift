import SwiftUI
import AppKit

@MainActor
struct StoragePane: View {
    @ObservedObject var settings: SettingsStore
    @State private var showResetConfirm = false
    @State private var showChangeSheet = false
    @State private var pendingFolder: URL?
    @State private var moveExisting = true
    @State private var deleteOld = false
    @State private var migrating = false
    @State private var progress = ""
    @State private var pendingBackupFolder: URL?
    @State private var showReductionDetails = false
    @State private var showCompactionDetails = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(settings.storageFolderPath)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
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
                        Text(progress.isEmpty ? "Applying storage changes…" : progress)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle("Backup older snapshots instead of deleting them", isOn: $settings.backupEnabled)
                    .help("During pruning, older snapshots move to the backup folder instead of being deleted.")

                if settings.backupEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(settings.backupFolderPath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        HStack(spacing: 8) {
                            Button("Reveal") {
                                let path = StoragePaths.backupDisplayPath()
                                guard path != "Not set" else { return }
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            Button("Choose…") { chooseBackupFolder() }
                            Button("Clear") {
                                StoragePaths.clearBackupFolder()
                                settings.backupFolderPath = StoragePaths.backupDisplayPath()
                            }
                        }
                    }
                }
            } header: {
                Text("Location")
            }

            Section {
                LabeledContent("Format") {
                    Picker("", selection: $settings.storageFormat) {
                        ForEach(SettingsStore.StorageFormat.allCases) { format in
                            Text(format.rawValue.uppercased()).tag(format)
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
                            .frame(width: 82, alignment: .trailing)
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
            } header: {
                Text("Encoding")
            } footer: {
                Text("Encoding changes apply to new snapshots.")
            }

            Section {
                Toggle("Skip near-duplicates", isOn: $settings.dedupEnabled)
                Toggle("Adaptive sampling", isOn: $settings.adaptiveSampling)
                Toggle("Refresh timeline on new snapshot", isOn: $settings.refreshOnNewSnapshot)

                DisclosureGroup("Details", isExpanded: $showReductionDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Dedup sensitivity") {
                            HStack {
                                Slider(
                                    value: Binding(get: { Double(settings.dedupHammingThreshold) }, set: { settings.dedupHammingThreshold = Int($0) }),
                                    in: 0...16,
                                    step: 1
                                )
                                .disabled(!settings.dedupEnabled)
                                Text("\(settings.dedupHammingThreshold)")
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                            }
                        }

                        LabeledContent("Max sampling interval") {
                            HStack {
                                Slider(value: $settings.adaptiveMaxInterval, in: 5.0...30.0, step: 5.0)
                                    .disabled(!settings.adaptiveSampling)
                                Text(String(format: "%.0f s", settings.adaptiveMaxInterval))
                                    .monospacedDigit()
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            } header: {
                Text("Capture Reduction")
            }

            Section {
                Toggle("Keep highlight boxes only for recent snapshots", isOn: $settings.recentOCRBoxesOnly)
                    .help("Older highlight boxes are pruned after the aging window to save database space.")
                    .onChange(of: settings.recentOCRBoxesOnly) { enabled in
                        guard enabled else { return }
                        triggerOCRBoxPrune()
                    }

                Toggle("Auto-compact older snapshots", isOn: $settings.autoCompactEnabled)
                    .help("Automatically rewrites older snapshots using the settings below.")
                    .onChange(of: settings.autoCompactEnabled) { enabled in
                        guard enabled else { return }
                        triggerStorageMaintenance()
                    }

                if settings.autoCompactEnabled {
                    DisclosureGroup("Compaction settings", isExpanded: $showCompactionDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Degrade after") {
                                HStack(spacing: 6) {
                                    TextField("", value: $settings.degradeAfterDays, formatter: Self.intFormatter)
                                        .frame(width: 70)
                                    Text("days")
                                        .foregroundColor(.secondary)
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
                        .padding(.top, 8)
                    }
                }
            } header: {
                Text("Aging & Compaction")
            } footer: {
                Text("Compaction can shrink older snapshots to save space while keeping recent data detailed.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permanently delete all app data, including the database, snapshots, backups, and settings.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Text("Delete All Data and Reset")
                    }
                }
            } header: {
                Text("Danger Zone")
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
                    guard let destination = pendingFolder else {
                        showChangeSheet = false
                        return
                    }
                    showChangeSheet = false
                    migrating = true
                    progress = ""
                    Task { @MainActor in
                        await StorageMigrationManager.shared.changeLocation(to: destination, moveExisting: moveExisting, deleteOld: deleteOld) { message in
                            Task { @MainActor in progress = message }
                        }
                        settings.storageFolderPath = StoragePaths.displayPath()
                        migrating = false
                        progress = ""
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 365
        return formatter
    }()
}

private struct DataResetConfirmSheet: View {
    var onCancel: () -> Void
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(.yellow)
                Text("Delete All Data?")
                    .font(.title3)
                    .bold()
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
    func triggerOCRBoxPrune() {
        DispatchQueue.global(qos: .utility).async {
            DB.shared.pruneOldOCRBoxesIfConfigured(force: true)
        }
    }

    func triggerStorageMaintenance() {
        DispatchQueue.global(qos: .utility).async {
            StorageMaintenanceManager.shared.runIfNeeded(forceMaintenance: true)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Storage Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
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
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
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
                Image(systemName: "externaldrive")
                    .font(.system(size: 28))
                Text("Change Storage Location")
                    .font(.title3)
                    .bold()
            }
            if let folder {
                Text("New folder:")
                    .font(.headline)
                Text(folder.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
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
