import SwiftUI

/// Recovery-passphrase entry shown when the vault key is missing from this Mac's keychain.
struct VaultRecoveryField: View {
    @ObservedObject var vault = VaultManager.shared
    @State private var passphrase = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The vault key isn't in this Mac's keychain. Enter your recovery passphrase to unlock and restore it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Recovery passphrase", text: $passphrase)
                    .frame(maxWidth: 260)
                    .onSubmit(submit)
                Button("Unlock", action: submit)
                    .disabled(passphrase.isEmpty || working)
                if working { ProgressView().controlSize(.small) }
            }
        }
    }

    private func submit() {
        guard !passphrase.isEmpty, !working else { return }
        working = true
        Task { @MainActor in
            if await vault.unlock(recoveryPassphrase: passphrase) { passphrase = "" }
            working = false
        }
    }
}
