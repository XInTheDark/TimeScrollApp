import SwiftUI
import AppKit

@MainActor
struct MCPSettingsPane: View {
    @AppStorage("settings.mcpEnabled") private var persistedEnabled: Bool = false
    @State private var showMigrationPrompt: Bool = false
    @State private var migrating: Bool = false
    @State private var migrationProgress: String = ""
    @State private var pendingEnableRequiresMigration: Bool = false

    var body: some View {
        MCPPane(
            mcpEnabled: toggleBinding,
            migrating: migrating,
            migrationProgress: migrationProgress
        )
        .sheet(isPresented: $showMigrationPrompt) {
            MCPMigrationConfirmSheet(onCancel: {
                pendingEnableRequiresMigration = false
                showMigrationPrompt = false
                persistedEnabled = false
                pendingEnableRequiresMigration = false
            }, onContinue: {
                showMigrationPrompt = false
                proceedEnableMCP()
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
                    pendingEnableRequiresMigration = false
                }
            }
        )
    }

    private func handleEnableRequest() {
        pendingEnableRequiresMigration = StoragePaths.needsLegacyMigrationForMCP()
        if pendingEnableRequiresMigration {
            showMigrationPrompt = true
            return
        }
        proceedEnableMCP()
    }

    private func beginLegacyMigration() {
        pendingEnableRequiresMigration = false
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

    private func proceedEnableMCP() {
        if pendingEnableRequiresMigration {
            beginLegacyMigration()
        } else {
            persistedEnabled = true
        }
    }
}

@MainActor
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
