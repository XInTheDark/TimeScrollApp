import SwiftUI

/// Presents `VaultManager.lastError` so failed vault operations are never silent.
struct VaultErrorAlert: ViewModifier {
    @ObservedObject var vault = VaultManager.shared

    func body(content: Content) -> some View {
        content.alert(
            "Encrypted Vault",
            isPresented: Binding(get: { vault.lastError != nil }, set: { if !$0 { vault.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vault.lastError ?? "")
        }
    }
}

extension View {
    func vaultErrorAlert() -> some View { modifier(VaultErrorAlert()) }
}
