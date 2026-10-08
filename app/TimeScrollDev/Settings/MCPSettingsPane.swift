import SwiftUI
import AppKit

@MainActor
struct MCPSettingsPane: View {
    @AppStorage("settings.mcpEnabled") private var persistedEnabled: Bool = false

    var body: some View {
        // The helper forwards searches to the app, so it needs no access to the storage
        // folder and enabling MCP requires no data migration.
        MCPPane(mcpEnabled: $persistedEnabled)
    }
}
