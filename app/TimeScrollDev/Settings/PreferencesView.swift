import SwiftUI
import AppKit

struct PreferencesView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacyPane(settings: settings)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            SearchPane(settings: settings)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            StoragePane(settings: settings)
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            UpdatesPane(settings: settings)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            StatsPane()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 380)
        .onDisappear { settings.flush() }
    }
}


private struct GeneralPane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            Section(header: Text("App")) {
                Toggle("Start minimized (menu bar only)", isOn: $settings.startMinimized)
                Toggle("Start recording on launch", isOn: $settings.startRecordingOnStart)
                Toggle("Show Dock icon when no window", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { newVal in
                        let anyVisible = NSApplication.shared.windows.contains { $0.isVisible }
                        if !anyVisible {
                            NSApplication.shared.setActivationPolicy(newVal ? .regular : .accessory)
                        }
                    }
            }
            Section(header: Text("OCR")) {
                LabeledContent("Recognition mode") {
                    Picker("", selection: $settings.ocrMode) {
                        ForEach(SettingsStore.OCRMode.allCases) { m in
                            Text(m.rawValue.capitalized).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                Text("OCR is used for text search. With Fast mode, the results will probably be messy.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Capture")) {
                LabeledContent("Min interval") {
                    HStack {
                        Slider(value: Self.minIntervalIndexBinding(settings: settings), in: 0...Double(Self.minIntervalOptions.count - 1), step: 1)
                        Text(Self.formatInterval(settings.captureMinInterval))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent("Retention") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.retentionDays, formatter: Self.intFormatter)
                            .frame(width: 70)
                        Text("days").foregroundColor(.secondary)
                    }
                }

                LabeledContent("Capture scale") {
                    HStack {
                        Slider(value: $settings.captureScale, in: 0.5...1.0, step: 0.05)
                        Text(String(format: "%.0f%%", settings.captureScale * 100))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .onChange(of: settings.captureScale) { _ in
                    Task { @MainActor in
                        await AppState.shared.restartCaptureIfRunning()
                    }
                }
                LabeledContent("Displays") {
                    Picker("", selection: $settings.captureDisplayMode) {
                        ForEach(SettingsStore.DisplayCaptureMode.allCases) { m in
                            Text(m == .first ? "First display" : "All displays").tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                .onChange(of: settings.captureDisplayMode) { _ in
                    Task { @MainActor in
                        await AppState.shared.restartCaptureIfRunning()
                    }
                }
                .onChange(of: settings.captureMinInterval) { newVal in
                    if settings.adaptiveMaxInterval < newVal { settings.adaptiveMaxInterval = newVal }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 365
        return f
    }()

    private static let minIntervalOptions: [Double] = [
        0.5, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 15.0, 20.0, 30.0
    ]

    private static func indexForInterval(_ value: Double) -> Int {
        var bestIdx = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (i, v) in minIntervalOptions.enumerated() {
            let d = abs(v - value)
            if d < bestDelta {
                bestDelta = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    private static func minIntervalIndexBinding(settings: SettingsStore) -> Binding<Double> {
        Binding<Double>(
            get: { Double(indexForInterval(settings.captureMinInterval)) },
            set: { newVal in
                let idx = max(0, min(minIntervalOptions.count - 1, Int(newVal.rounded())))
                settings.captureMinInterval = minIntervalOptions[idx]
            }
        )
    }

    private static func formatInterval(_ value: Double) -> String {
        if value < 1.0 { return String(format: "%.1f s", value) }
        if value < 10.0 { return String(format: "%.1f s", value) }
        return String(format: "%.0f s", value)
    }
}

private struct SearchPane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            Section(header: Text("Search behavior")) {
                LabeledContent("Fuzziness") {
                    Picker("", selection: $settings.fuzziness) {
                        ForEach(SettingsStore.Fuzziness.allCases) { f in
                            Text(f.rawValue.capitalized).tag(f)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
                Toggle("Show highlight boxes", isOn: $settings.showHighlights)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StatsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatsView()
        }
    }
}

private struct StoragePane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            Section(header: Text("Encoding")) {
                LabeledContent("Format") {
                    Picker("", selection: $settings.storageFormat) {
                        ForEach(SettingsStore.StorageFormat.allCases) { f in
                            Text(f.rawValue.uppercased()).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }

                LabeledContent("Max long edge") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.maxLongEdge) }, set: { settings.maxLongEdge = Int($0) }), in: 0...3000, step: 100)
                        Text(settings.maxLongEdge == 0 ? "Original" : "\(settings.maxLongEdge) px")
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                }

                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $settings.lossyQuality, in: 0.3...0.9, step: 0.05)
                        Text(String(format: "%.2f", settings.lossyQuality))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section(header: Text("Capture reduction")) {
                Toggle("Skip near-duplicates", isOn: $settings.dedupEnabled)

                LabeledContent("Dedup sensitivity") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.dedupHammingThreshold) }, set: { settings.dedupHammingThreshold = Int($0) }), in: 0...16, step: 1)
                        Text("\(settings.dedupHammingThreshold)")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                Toggle("Adaptive sampling", isOn: $settings.adaptiveSampling)

                LabeledContent("Max interval") {
                    HStack {
                        Slider(value: $settings.adaptiveMaxInterval, in: 2...20, step: 1)
                        Text(String(format: "%.0f s", settings.adaptiveMaxInterval))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                Toggle("Refresh timeline on new snapshot", isOn: $settings.refreshOnNewSnapshot)
            }
            Section(header: Text("Aging & compaction")) {
                LabeledContent("Degrade after") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.degradeAfterDays, formatter: Self.intFormatter)
                            .frame(width: 70)
                        Text("days").foregroundColor(.secondary)
                    }
                }

                LabeledContent("Degrade size") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.degradeMaxLongEdge) }, set: { settings.degradeMaxLongEdge = Int($0) }), in: 600...2000, step: 100)
                        Text("\(settings.degradeMaxLongEdge) px")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }

                LabeledContent("Degrade quality") {
                    HStack {
                        Slider(value: $settings.degradeQuality, in: 0.3...0.8, step: 0.05)
                        Text(String(format: "%.2f", settings.degradeQuality))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section(header: Text("Delete")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permanently delete ALL app data, including database, snapshots, and settings. This cannot be undone.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button(role: .destructive) { DataReset.wipeAllAppData() } label: { Text("Delete All Data and Reset") }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 365
        return f
    }()
}
