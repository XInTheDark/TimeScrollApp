import SwiftUI

/// Asks for the recovery passphrase that is required to turn on the encrypted vault.
struct VaultPassphraseSheet: View {
    var onCancel: () -> Void
    var onConfirm: (_ passphrase: String) -> Void

    @State private var passphrase = ""
    @State private var confirmation = ""

    private var problem: String? {
        if passphrase.count < VaultManager.minimumPassphraseLength {
            return "Use at least \(VaultManager.minimumPassphraseLength) characters."
        }
        if passphrase != confirmation { return "The passphrases do not match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.system(size: 26))
                Text("Set a Recovery Passphrase").font(.title3).bold()
            }
            Text("TimeScroll keeps the vault key in your login keychain and unlocks it with Touch ID or your Mac password. If that key is ever lost (for example on a new Mac or after resetting the keychain), this passphrase is the only way to recover your encrypted data.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Recovery passphrase", text: $passphrase)
            SecureField("Confirm passphrase", text: $confirmation)
            if let problem, !passphrase.isEmpty {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
            Label("Store it somewhere safe. It cannot be reset.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Enable Encryption") { onConfirm(passphrase) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(18)
        .frame(width: 480)
    }
}
