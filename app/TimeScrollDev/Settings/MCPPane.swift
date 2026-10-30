import SwiftUI

struct MCPPane: View {
    @Binding var mcpEnabled: Bool

    @State private var jsonText: String
    @State private var logStatus: String?

    init(mcpEnabled: Binding<Bool>) {
        self._mcpEnabled = mcpEnabled
        let helper = Self.helperExecutable(for: Bundle.main.bundleURL)
        self._jsonText = State(initialValue: Self.makeConfigJSON(helperPath: helper))
    }

    private static func helperExecutable(for bundleURL: URL) -> String {
        bundleURL
            .appendingPathComponent("Contents/Helpers/timescroll-mcp.app/Contents/MacOS/timescroll-mcp")
            .path
    }

    private static func makeConfigJSON(helperPath: String) -> String {
        // The bundle may live in a folder whose name needs JSON escaping.
        let command = helperPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
            "mcpServers": {
                "timescroll": {
                    "type": "stdio",
                    "command": "\(command)",
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
                Text("MCP clients search through the running TimeScroll app, which opens in the background when needed. While the vault is locked, searches are refused.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

            Section(header: Text("Claude Code")) {
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
                    HStack(spacing: 8) {
                        Button("Show Logs in Finder") { revealLogs() }
                        Button("Clear Logs") { clearLogs() }
                    }
                    .buttonStyle(.bordered)
                    Text(logStatus ?? "Logs record request sizes and timings only, never queries or results.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func revealLogs() {
        let url = logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Nothing has been logged yet: open the folder instead of silently doing nothing.
            _ = NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func clearLogs() {
        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                try FileManager.default.removeItem(at: logURL)
            }
            logStatus = "Logs cleared."
        } catch {
            logStatus = "Could not clear logs: \(error.localizedDescription)"
        }
    }

    private var logURL: URL {
        StoragePaths.sharedLogURL(filename: "timescroll-mcp.log")
    }
}
