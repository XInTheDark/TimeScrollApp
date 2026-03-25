import SwiftUI

struct MCPPane: View {
    @Binding var mcpEnabled: Bool
    var migrating: Bool
    var migrationProgress: String

    @State private var jsonText: String

    init(mcpEnabled: Binding<Bool>, migrating: Bool, migrationProgress: String) {
        self._mcpEnabled = mcpEnabled
        self.migrating = migrating
        self.migrationProgress = migrationProgress
        let helper = Self.helperExecutable(for: Bundle.main.bundleURL)
        self._jsonText = State(initialValue: Self.makeConfigJSON(helperPath: helper))
    }

    private static func helperExecutable(for bundleURL: URL) -> String {
        bundleURL
            .appendingPathComponent("Contents/Helpers/timescroll-mcp.app/Contents/MacOS/timescroll-mcp")
            .path
    }

    private static func makeConfigJSON(helperPath: String) -> String {
        """
        {
            "mcpServers": {
                "timescroll": {
                    "type": "stdio",
                    "command": "\(helperPath)",
                    "args": [],
                    "env": {}
                }
            }
        }
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var helperPath: String { Self.helperExecutable(for: Bundle.main.bundleURL) }
    private var cliSnippet: String { "claude mcp add --transport stdio timescroll -- \"\(helperPath)\"" }

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
        StoragePaths.sharedLogURL(filename: "timescroll-mcp.log")
    }
}
