import SwiftUI
import AppKit

struct AboutPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPaneScrollView {
            aboutHeader

            SettingsSectionCard(title: "Support Development") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TimeScroll will stay free forever. If it has been useful, you can help support future work.")
                        .fixedSize(horizontal: false, vertical: true)

                    Link("Buy me a coffee on Ko-fi", destination: URL(string: "https://ko-fi.com/jmuzhen")!)
                }
            }

            SettingsSectionCard(title: "Advanced") {
                Toggle("Debug mode", isOn: $settings.debugMode)
            }
        }
    }

    private var aboutHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(appName)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Version \(appVersion)")
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .settingsInsetCard(padding: 20)
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TimeScroll"
    }

    private var appVersion: String {
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let b = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }
}
