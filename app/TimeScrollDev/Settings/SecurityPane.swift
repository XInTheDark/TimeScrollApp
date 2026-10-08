import SwiftUI
import AppKit

@MainActor
struct SecurityPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var vault = VaultManager.shared
    @State private var showVaultOnboarding: Bool = false
    @State private var showVaultPassphrase: Bool = false
    @State private var pendingEnableVault: Bool = false
    @State private var showVaultDisableSheet: Bool = false
    @State private var pendingDisableVault: Bool = false
    var body: some View {
        Form {
            Section(header: Text("Encrypted Vault")) {
                Toggle("Enable encrypted vault", isOn: Binding(get: { settings.vaultEnabled }, set: { newVal in
                    if newVal {
                        pendingEnableVault = true
                        // Show onboarding/confirmation the first time (or if user hasn't opted out)
                        let seen = UserDefaults.standard.bool(forKey: "vault.onboardingShown")
                        if !seen {
                            showVaultOnboarding = true
                            return
                        }
                        showVaultPassphrase = true
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
                    settings.vaultEnabled = newVal
                }))
                Toggle("Allow screen capture while locked", isOn: $settings.captureWhileLocked)
                Text("Audio capture pauses while the vault is locked and resumes after unlock.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(header: Text("Auto-lock")) {
                Toggle("Lock on sleep/wake", isOn: $settings.autoLockOnSleep)
                LabeledContent("After inactivity") {
                    SettingsNumberField(value: $settings.autoLockInactivityMinutes, formatter: Self.intFormatter, unit: "minutes")
                }
            }
            Section(header: Text("Controls")) {
                HStack(spacing: 12) {
                    Button("Unlock…") { Task { await vault.unlock(presentingWindow: NSApp.keyWindow) } }
                        .disabled(!settings.vaultEnabled || vault.isUnlocked)
                    Button("Lock") { Task { await vault.lock() } }
                        .disabled(!settings.vaultEnabled || !vault.isUnlocked)
                }
                if settings.vaultEnabled && vault.needsRecoveryPassphrase && !vault.isUnlocked {
                    VaultRecoveryField()
                }
                if settings.vaultEnabled && vault.queuedCount > 0 {
                    Text("Queued: \(vault.queuedCount)").font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .vaultErrorAlert()
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
                showVaultOnboarding = false
                showVaultPassphrase = true
            })
        }
        .sheet(isPresented: $showVaultDisableSheet) {
            VaultDisableConfirmSheet(onCancel: {
                // Keep encryption ON
                pendingDisableVault = false
                showVaultDisableSheet = false
            }, onContinue: {
                // Turn off encryption and lock the vault immediately
                Task { @MainActor in await VaultManager.shared.disableVault() }
                pendingDisableVault = false
                showVaultDisableSheet = false
            })
        }
        .sheet(isPresented: $showVaultPassphrase) {
            VaultPassphraseSheet(onCancel: {
                settings.vaultEnabled = false
                pendingEnableVault = false
                showVaultPassphrase = false
            }, onConfirm: { passphrase in
                showVaultPassphrase = false
                pendingEnableVault = false
                Task { @MainActor in await VaultManager.shared.enableVault(recoveryPassphrase: passphrase) }
            })
        }
    }

    private static var intFormatter: NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 0; f.maximum = 600; return f
    }
}

@MainActor
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

@MainActor
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
