import SwiftUI
import AppKit

struct UpdatesPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section(header: Text("Channel")) {
                Toggle("Include beta/pre-release updates", isOn: $settings.updateChannelBeta)
                    .onChange(of: settings.updateChannelBeta) { _ in applySparkle() }
                Text(settings.updateChannelBeta
                     ? "You will receive updates from the beta feed."
                     : "You will receive updates from the stable feed.")
                .font(.footnote)
                .foregroundColor(.secondary)
            }

            Section(header: Text("Automatic updates")) {
                Toggle("Automatically check for updates", isOn: $settings.enableAutoCheckUpdates)
                    .onChange(of: settings.enableAutoCheckUpdates) { _ in applySparkle() }

                LabeledContent("Check interval") {
                    HStack {
                        Slider(value: Binding(get: { Double(settings.autoCheckIntervalHours) },
                                              set: { settings.autoCheckIntervalHours = Int($0) }),
                               in: 12...168, step: 12)
                        Text("\(settings.autoCheckIntervalHours) h")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .onChange(of: settings.autoCheckIntervalHours) { _ in applySparkle() }

                Toggle("Automatically download and install updates", isOn: $settings.autoDownloadInstallUpdates)
                    .onChange(of: settings.autoDownloadInstallUpdates) { _ in applySparkle() }

                Text("On your first launch after a update, you may see a first‑run Gatekeeper prompt.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Manual")) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .TimeScrollCheckForUpdates, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { applySparkle() }
    }

    private func applySparkle() {
        NotificationCenter.default.post(name: .TimeScrollApplyUpdatePrefs, object: nil)
    }
}
