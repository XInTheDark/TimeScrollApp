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

            TextField("Search snapshots", text: $query)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { applyFiltersAndLoad() }

            Button(showFilters ? "Hide Filters" : "Filters") {
                showFilters.toggle()
            }

            if showFilters { filtersPanel }

            Button("Go") { applyFiltersAndLoad() }
                .keyboardShortcut(.return)

            Spacer()

            // Zoom controls
            HStack(spacing: 6) {
                Button("−") { model.msPerPoint = max(minMsPerPt, model.msPerPoint / 2) }
                Slider(value: Binding(get: {
                    // Map msPerPoint to 0...1 for slider
                    let clamped = min(max(model.msPerPoint, minMsPerPt), maxMsPerPt)
                    return (clamped - minMsPerPt) / (maxMsPerPt - minMsPerPt)
                }, set: { v in
                    model.msPerPoint = minMsPerPt + v * (maxMsPerPt - minMsPerPt)
                }))
                .frame(width: 140)
                Button("+") { model.msPerPoint = min(maxMsPerPt, model.msPerPoint * 2) }
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
            SnapshotStageView(model: model, globalQuery: model.query)
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

    private func applyFiltersAndLoad() {
        model.query = query
        model.startMs = startDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        model.endMs = endDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        model.load()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) {
                return event
            }
            if let first = NSApp.keyWindow?.firstResponder, first is NSTextView {
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
