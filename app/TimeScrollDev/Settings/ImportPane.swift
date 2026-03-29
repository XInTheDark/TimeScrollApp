import SwiftUI
import AppKit

@MainActor
struct ImportPane: View {
    @StateObject private var importer = ScreenMemoryImporter()
    @State private var folderPath: String = {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ScreenMemoryData").path
        return FileManager.default.fileExists(atPath: defaultPath) ? defaultPath : ""
    }()
    @State private var showFolderPicker = false

    private var folderURL: URL? {
        guard !folderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: folderPath)
    }

    private var isValidFolder: Bool {
        guard let url = folderURL else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("text.sqlite").path)
            && fm.fileExists(atPath: url.appendingPathComponent("usage.sqlite").path)
            && fm.fileExists(atPath: url.appendingPathComponent("screenshots").path)
    }

    var body: some View {
        SettingsPaneScrollView {
            SettingsSectionCard(title: "Import from ScreenMemory",
                                subtitle: "Import screenshots and OCR text from a ScreenMemory data folder.") {
                // Folder selection
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(folderPath.isEmpty ? "No folder selected" : folderPath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundColor(folderPath.isEmpty ? .secondary : .primary)

                        Spacer()

                        Button("Browse...") {
                            chooseFolder()
                        }
                    }

                    if !folderPath.isEmpty {
                        if isValidFolder {
                            Label("Valid ScreenMemory data folder", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        } else {
                            Label("Missing text.sqlite, usage.sqlite, or screenshots/", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }

                Divider()

                // Actions
                switch importer.state {
                case .idle:
                    actionButtons

                case .running:
                    runningView

                case .done(let ok, let skipped, let errors):
                    doneView(imported: ok, skipped: skipped, errors: errors)

                case .failed(let msg):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Reset") { importer.state = .idle }
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test import copies 5 screenshots spread across your full history. Full import moves all files to save disk space.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Test Import (5 screenshots)") {
                    guard let url = folderURL else { return }
                    importer.startTest(folder: url)
                }
                .disabled(!isValidFolder)

                Button("Import All (Move)") {
                    guard let url = folderURL else { return }
                    importer.startFull(folder: url)
                }
                .disabled(!isValidFolder)

            }
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if importer.total > 0 {
                ProgressView(value: Double(importer.imported), total: Double(importer.total))
            } else {
                ProgressView()
            }

            Text(importer.progress)
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Cancel") {
                importer.cancel()
            }
        }
    }

    private func doneView(imported: Int, skipped: Int, errors: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Import complete", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)

            HStack(spacing: 16) {
                Label("\(imported) imported", systemImage: "photo")
                if skipped > 0 {
                    Label("\(skipped) skipped", systemImage: "arrow.right.arrow.left")
                        .foregroundColor(.secondary)
                }
                if errors > 0 {
                    Label("\(errors) errors", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
            }
            .font(.caption)

            HStack(spacing: 12) {
                if !importer.testItems.isEmpty {
                    Button("Undo Test Import") {
                        importer.undoTest()
                    }
                }
                Button("Reset") {
                    importer.state = .idle
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your ScreenMemoryData folder"
        panel.directoryURL = folderURL ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
