import SwiftUI

struct MCPPane: View {
        @Binding var mcpEnabled: Bool
        var migrating: Bool
        var migrationProgress: String

        private static let helperExecutable = "/Applications/TimeScroll.app/Contents/Helpers/timescroll-mcp.app/Contents/MacOS/timescroll-mcp"
        private static let defaultJSON: String = {
                let helper = helperExecutable
                return """
                {
                    "mcpServers": {
                        "timescroll": {
                            "type": "stdio",
                            "command": "\(helper)",
                            "args": [],
                            "env": {}
                        }
                    }
                }
                """.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        private var helperPath: String { Self.helperExecutable }
        private var cliSnippet: String { "claude mcp add --transport stdio timescroll -- \"\(helperPath)\"" }
        @State private var jsonText: String = MCPPane.defaultJSON

    var body: some View {
        Form {
            Section(header: Text("Enable MCP")) {
                Toggle("Enable MCP tools", isOn: $mcpEnabled)
                    .disabled(migrating)
                if migrating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(migrationProgress.isEmpty ? "Moving data…" : migrationProgress)
                    }
                }
            }

            Section(header: Text("Install MCP server")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Config JSON").font(.headline)
                    TextEditor(text: $jsonText)
                        .font(.system(.footnote, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    HStack {
                        Button("Copy JSON") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(jsonText, forType: .string)
                        }
                        Spacer()
                    }
                }
            }

            Section(header: Text("Claude Desktop")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install command").font(.headline)
                    HStack(spacing: 8) {
                        Text(cliSnippet)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cliSnippet, forType: .string)
                        }
                    }
                }
            }

            Section(header: Text("Logs")) {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Open Logs") { revealLogs() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func revealLogs() {
        guard let url = logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var logURL: URL? {
        let appGroupID = "group.com.muzhen.TimeScroll.shared"
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        return container.appendingPathComponent("Logs/timescroll-mcp.log")
    }
}
