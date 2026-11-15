import SwiftUI

/// Asks for the recovery passphrase that is required to turn on the encrypted vault: a new one
/// for a new vault, or the existing one when this storage folder already has a vault.
struct VaultPassphraseSheet: View {
    enum Mode { case create, existingVault }

    var mode: Mode = .create
    var onCancel: () -> Void
    var onConfirm: (_ passphrase: String) -> Void
    /// Existing-vault mode only: replace the vault instead (confirmed separately).
    var onStartNewVault: () -> Void = {}

    @State private var passphrase = ""
    @State private var confirmation = ""

    private var problem: String? {
        if passphrase.count < VaultManager.minimumPassphraseLength {
            return "Use at least \(VaultManager.minimumPassphraseLength) characters."
        }
        if mode == .create, passphrase != confirmation { return "The passphrases do not match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 26))
                Text(mode == .create ? "Set a Recovery Passphrase" : "Enter Your Recovery Passphrase").font(.title3).bold()
            }
            switch mode {
            case .create:
                Text("TimeScroll keeps the vault key in your login keychain and unlocks it with Touch ID or your Mac password. If that key is ever lost (for example on a new Mac or after resetting the keychain), this passphrase is the only way to recover your encrypted data.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Recovery passphrase", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirmation)
            case .existingVault:
                Text("This storage folder already has an encrypted vault, and its key isn't in this Mac's keychain. Enter the vault's recovery passphrase to turn encryption back on and keep access to your encrypted data.")
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Recovery passphrase", text: $passphrase)
                    .onSubmit { if problem == nil { onConfirm(passphrase) } }
            }
            if let problem, !passphrase.isEmpty {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
            if mode == .create {
                Label("Store it somewhere safe. It cannot be reset.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack {
                if mode == .existingVault {
                    Button("Start a New Vault…") { onStartNewVault() }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Enable Encryption") { onConfirm(passphrase) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(18)
        .frame(width: 480)
    }
}
