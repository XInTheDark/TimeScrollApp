import SwiftUI

struct LockedView: View {
    @ObservedObject var vault = VaultManager.shared
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 48)).foregroundColor(.secondary)
            Text("Vault is locked").font(.title3).bold()
            if vault.queuedCount > 0 {
                Text("Queued items will be stored after unlock.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Button("Unlock…") { Task { await vault.unlock(presentingWindow: NSApp.keyWindow) } }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
