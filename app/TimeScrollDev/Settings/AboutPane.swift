import SwiftUI
import AppKit

struct AboutPane: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var showAdvanced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .cornerRadius(12)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(appName)
                        .font(.title2).bold()
                    Text("Version \(appVersion)")
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("This app will always be free! If you find it nice, please consider supporting development! ❤️")
                Link("Buy me a coffee on Ko‑fi", destination: URL(string: "https://ko-fi.com/jmuzhen")!)
            }
            .font(.body)

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Debug mode", isOn: $settings.debugMode)
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced")
                    .font(.headline)
            }

            Spacer()
        }
        .padding(.top, 8)
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
