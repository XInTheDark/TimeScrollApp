import SwiftUI
import AppKit

@MainActor
struct GeneralPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var showAccessibilityPrompt = false
    @AppStorage("ui.timeline.invertScrollDirection") private var invertTimelineScrollDirection: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Start minimized (menu bar only)", isOn: $settings.startMinimized)
                Toggle("Start recording on launch", isOn: $settings.startRecordingOnStart)
                Toggle("Show Dock icon when no window", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { newValue in
                        let hasUserWindow = NSApplication.shared.ts_hasVisibleUserWindow
                        if !hasUserWindow {
                            NSApplication.shared.setActivationPolicy(newValue ? .regular : .accessory)
                        }
                    }
            } header: {
                Text("App")
            }

            Section {
                LabeledContent("Mode") {
                    Picker("", selection: $settings.textProcessingMode) {
                        Text("Direct").tag(SettingsStore.TextProcessingMode.accessibility)
                        Text("Legacy (OCR)").tag(SettingsStore.TextProcessingMode.ocr)
                        Text("None").tag(SettingsStore.TextProcessingMode.none)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .onChange(of: settings.textProcessingMode) { newValue in
                        if newValue == .accessibility && !Permissions.isAccessibilityGranted() {
                            showAccessibilityPrompt = true
                        }
                    }
                }

                if settings.textProcessingMode == .ocr {
                    LabeledContent("OCR mode") {
                        Picker("", selection: $settings.ocrMode) {
                            ForEach(SettingsStore.OCRMode.allCases) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }
                }
            } header: {
                Text("Text Processing")
            } footer: {
                Text(textProcessingFooter)
            }
            .sheet(isPresented: $showAccessibilityPrompt) {
                AccessibilityPermissionSheet(
                    onCancel: {
                        showAccessibilityPrompt = false
                        settings.textProcessingMode = .ocr
                    },
                    onContinue: {
                        Permissions.requestAccessibility()
                        showAccessibilityPrompt = false
                    }
                )
            }

            Section {
                LabeledContent("Min interval") {
                    HStack {
                        Slider(value: Self.minIntervalIndexBinding(settings: settings), in: 0...Double(Self.minIntervalOptions.count - 1), step: 1)
                        Text(Self.formatInterval(settings.captureMinInterval))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                LabeledContent("Retention") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.retentionDays, formatter: Self.intFormatter)
                            .frame(width: 70)
                        Text("days")
                            .foregroundColor(.secondary)
                    }
                }

                LabeledContent("Capture scale") {
                    HStack {
                        Slider(value: $settings.captureScale, in: 0.5...1.0, step: 0.05)
                        Text(String(format: "%.0f%%", settings.captureScale * 100))
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                .onChange(of: settings.captureScale) { _ in
                    Task { @MainActor in
                        await AppState.shared.restartCaptureIfRunning()
                    }
                }

                LabeledContent("Displays") {
                    Picker("", selection: $settings.captureDisplayMode) {
                        ForEach(SettingsStore.DisplayCaptureMode.allCases) { mode in
                            Text(mode == .first ? "First display" : "All displays").tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                .onChange(of: settings.captureDisplayMode) { _ in
                    Task { @MainActor in
                        await AppState.shared.restartCaptureIfRunning()
                    }
                }
                .onChange(of: settings.captureMinInterval) { newValue in
                    if settings.adaptiveMaxInterval < newValue {
                        settings.adaptiveMaxInterval = newValue
                    }
                }
            } header: {
                Text("Capture")
            }

            Section {
                Toggle("Invert scroll direction", isOn: $invertTimelineScrollDirection)
            } header: {
                Text("Timeline")
            } footer: {
                Text("Invert the timeline wheel direction if your mouse or utility app feels backwards here.")
            }

            Section {
                Button("Show Onboarding") {
                    settings.onboardingCompleted = false
                    NotificationCenter.default.post(name: NSNotification.Name("ShowOnboarding"), object: nil)
                }
            } header: {
                Text("Setup")
            }
        }
        .formStyle(.grouped)
    }

    private var textProcessingFooter: String {
        switch settings.textProcessingMode {
        case .accessibility:
            return "Direct mode reads text through macOS Accessibility and usually uses much less energy than OCR."
        case .ocr:
            return "Legacy OCR works even when Accessibility text is unavailable, but it is slower and more power hungry."
        case .none:
            return "Text extraction is disabled. Search and highlights will only use saved snapshot metadata."
        }
    }

    private static var intFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 365
        return formatter
    }()

    private static let minIntervalOptions: [Double] = [
        0.5, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 15.0, 20.0, 30.0
    ]

    private static func indexForInterval(_ value: Double) -> Int {
        var bestIndex = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (index, candidate) in minIntervalOptions.enumerated() {
            let delta = abs(candidate - value)
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func minIntervalIndexBinding(settings: SettingsStore) -> Binding<Double> {
        Binding(
            get: { Double(indexForInterval(settings.captureMinInterval)) },
            set: { newValue in
                let index = max(0, min(minIntervalOptions.count - 1, Int(newValue.rounded())))
                settings.captureMinInterval = minIntervalOptions[index]
            }
        )
    }

    private static func formatInterval(_ value: Double) -> String {
        if value < 10.0 { return String(format: "%.1f s", value) }
        return String(format: "%.0f s", value)
    }
}

@MainActor
private struct AccessibilityPermissionSheet: View {
    var onCancel: () -> Void
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 28))
                Text("Enable Accessibility Access")
                    .font(.title3)
                    .bold()
            }
            Text("TimeScroll can read on-screen text via macOS Accessibility. This uses much less energy than OCR.")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Label("Open System Settings → Privacy & Security → Accessibility and allow TimeScroll.", systemImage: "gearshape")
                Label("After granting access, switch back to Direct mode or reopen this pane.", systemImage: "checkmark.circle")
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Open Settings") { onContinue() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
    }
}
