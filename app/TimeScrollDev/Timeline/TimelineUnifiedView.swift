import SwiftUI
import AppKit

struct TimelineUnifiedView: View {
    @ObservedObject var appState = AppState.shared
    @StateObject var model = TimelineModel()
    @EnvironmentObject var settings: SettingsStore

    @State private var query: String = ""
    @State private var showFilters: Bool = false
    @State private var startDate: Date? = nil
    @State private var endDate: Date? = nil
    @State private var keyMonitor: Any? = nil
    @State private var showingResults: Bool = false

    private let minMsPerPt: Double = 1_000
    private let maxMsPerPt: Double = 3_600_000

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            centerStage
            Divider()
            bottomTimeline
        }
        .onAppear {
            _ = SnapshotStore.shared.snapshotsDir
            appState.enforceRetention()
            model.load()
            installKeyMonitor()
            // Keep the text field in sync with the applied model query
            query = model.query
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: appState.lastSnapshotURL) { _ in
            if SettingsStore.shared.refreshOnNewSnapshot {
                let selId = model.selected?.id
                model.load()
                if model.followLatest {
                    model.selectedIndex = model.metas.isEmpty ? -1 : 0
                    model.jumpToEndToken &+= 1
                } else if let id = selId, let idx = model.metas.firstIndex(where: { $0.id == id }) {
                    model.selectedIndex = idx
                }
            }
        }
        // If the user clears the search field, automatically return to timeline
        .onChange(of: query) { newVal in
            let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && showingResults {
                // Clear applied query on the model and reload latest
                model.query = ""
                model.load()
                showingResults = false
            }
        }
        // Keep text field reflecting the currently applied model query (e.g. after programmatic changes)
        .onChange(of: model.query) { newVal in
            if query != newVal { query = newVal }
        }
        .frame(minWidth: 1000, minHeight: 700)
    }

    @State private var debugOpen: Bool = false

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(appState.isCapturing ? "Stop Capture" : "Start Capture") {
                Task {
                    if appState.isCapturing {
                        await appState.captureManager.stop()
                        appState.isCapturing = false
                    } else {
                        Permissions.requestScreenRecording()
                        try? await appState.captureManager.start()
                        appState.isCapturing = true
                    }
                }
            }
            if let url = appState.lastSnapshotURL, settings.debugMode {
                Text("Last: \(url.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().frame(height: 18)

            // Keep search field a sensible size; don't let it expand endlessly
            TextField("Search snapshots", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, maxWidth: 340)
                .submitLabel(.search)
                .onSubmit { showResults() }

            Button(showFilters ? "Hide Filters" : "Filters") {
                showFilters.toggle()
            }

            if showFilters { filtersPanel }

            Menu("Search") {
                Button("Show Results") { showResults() }
                // Keep Cmd+Return for power users; plain Return should not be global
                Button("Search & Jump") { searchAndJump() }
                    .keyboardShortcut(.return, modifiers: [.command])
            } primaryAction: {
                showResults()
            }
            .menuStyle(.borderedButton)
            // Make the pull‑down size to its label only
            .fixedSize()
            .controlSize(.regular)

            Spacer()

            // Zoom controls
            HStack(spacing: 6) {
                Button(action: { model.msPerPoint = max(minMsPerPt, model.msPerPoint / 2) }) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.bordered)
                Slider(value: Binding(get: {
                    // Map msPerPoint to 0...1 for slider
                    let clamped = min(max(model.msPerPoint, minMsPerPt), maxMsPerPt)
                    return (clamped - minMsPerPt) / (maxMsPerPt - minMsPerPt)
                }, set: { v in
                    model.msPerPoint = minMsPerPt + v * (maxMsPerPt - minMsPerPt)
                }))
                .frame(width: 140)
                Button(action: { model.msPerPoint = min(maxMsPerPt, model.msPerPoint * 2) }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
            }

            Toggle("Live", isOn: $model.followLatest)
                .toggleStyle(.switch)

            if settings.debugMode {
                Button("Debug DB") { debugOpen = true }
            }
        }
        .padding(8)
        .sheet(isPresented: $debugOpen) { DebugView() }
    }

    private var filtersPanel: some View {
        HStack(spacing: 8) {
            DatePicker("From", selection: Binding(get: { startDate ?? Date() }, set: { startDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            DatePicker("To", selection: Binding(get: { endDate ?? Date() }, set: { endDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            TimelineAppFilterMenu(selected: Binding(get: { model.selectedAppBundleId }, set: { model.selectedAppBundleId = $0 }))
        }
    }

    private var centerStage: some View {
        ZStack {
            // Use the applied model.query (not the in-flight text field value)
            Group {
                if showingResults {
                    SearchResultsView(query: model.query,
                                      appBundleId: model.selectedAppBundleId,
                                      startMs: model.startMs,
                                      endMs: model.endMs,
                                      onOpen: { row, absIndex in
                                          // Ensure timeline has enough items to include selection
                                          let limitNeeded = max(absIndex + 1, 50)
                                          model.load(limit: limitNeeded)
                                          if let idx = model.metas.firstIndex(where: { $0.id == row.id }) {
                                              model.selectedIndex = idx
                                          } else {
                                              model.selectedIndex = model.metas.isEmpty ? -1 : 0
                                          }
                                          showingResults = false
                                      },
                                      onClose: {
                                          // Closing search should restore the timeline view
                                          // Keep the applied query so timeline can remain filtered if desired
                                          model.load()
                                          showingResults = false
                                      })
                        // Remount the results view when filters change to avoid stale local state
                        .id("\(model.query)|\(model.selectedAppBundleId ?? "_")|\(model.startMs ?? -1)|\(model.endMs ?? -1)")
                        .environmentObject(settings)
                } else {
                    SnapshotStageView(model: model, globalQuery: model.query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomTimeline: some View {
        ZStack(alignment: .bottomTrailing) {
            TimelineBarContainer(model: model,
                                 onJump: { t in model.jump(to: t) },
                                 onHover: { t in model.hoverTimeMs = t },
                                 onHoverExit: { model.hoverTimeMs = nil })
                .frame(height: 100)

            Button(action: { jumpToEnd() }) {
                Image(systemName: "chevron.right.to.line")
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    private func applyFilters() {
        model.query = query
        model.startMs = startDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        model.endMs = endDate.map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private func showResults() {
        applyFilters()
        // Keep model.metas in sync so navigation uses the same result set
        model.load()
        showingResults = true
    }

    private func searchAndJump() {
        applyFilters()
        model.load()
        showingResults = false
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // If typing in the search field (NSTextView), intercept Cmd+Return to run Search & Jump
            if let first = NSApp.keyWindow?.firstResponder, first is NSTextView {
                // keyCode 36 = Return, 76 = keypad Enter
                if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) {
                    searchAndJump()
                    return nil
                }
                return event
            }
            // Ignore other modified keypresses
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) {
                return event
            }
            switch event.keyCode {
            case 123: // left
                if model.selectedIndex + 1 < model.metas.count { model.prev(); return nil }
            case 124: // right
                if model.selectedIndex - 1 >= 0 { model.next(); return nil }
            case 51, 117: // delete, forward delete
                if let sel = model.selected {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Delete Snapshot?"
                    alert.informativeText = "This will permanently delete the selected snapshot from disk and remove it from the timeline."
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        model.deleteSnapshot(id: sel.id)
                        return nil
                    }
                }
            default:
                break
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func jumpToEnd() {
        if !model.metas.isEmpty { model.selectedIndex = 0 }
        model.jumpToEndToken &+= 1
    }
}

private struct TimelineAppFilterMenu: View {
    @Binding var selected: String?
    @State private var apps: [(bundleId: String, name: String)] = []
    @State private var token: String = ""
    var body: some View {
        Picker("App", selection: $token) {
            Text("All Apps").tag("")
            ForEach(apps, id: \.bundleId) { entry in
                Text(entry.name).tag(entry.bundleId)
            }
        }
        .pickerStyle(.menu)
        .onAppear {
            load(); token = selected ?? ""
        }
        .onChange(of: selected) { sel in token = sel ?? "" }
        .onChange(of: token) { val in selected = val.isEmpty ? nil : val }
    }

    private func load() {
        if let list = try? DB.shared.distinctApps() { apps = list }
    }
}
