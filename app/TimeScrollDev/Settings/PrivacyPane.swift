import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PrivacyPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blacklisted Apps")
                .font(.headline)

            Text("When any app below is frontmost, TimeScroll will skip captures.")
                .font(.footnote)
                .foregroundColor(.secondary)

            List(selection: $selection) {
                ForEach(settings.blacklistBundleIds, id: \.self) { bid in
                    HStack(spacing: 8) {
                        AppIconView(bundleId: bid)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appDisplayName(for: bid))
                            Text(bid)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .tag(bid)
                }
            }
            .frame(minHeight: 220)

            HStack(spacing: 8) {
                Button(action: addApps) {
                    Label("Add App…", systemImage: "plus")
                }

                Button(role: .destructive, action: removeSelected) {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selection.isEmpty)

                Spacer()
            }
        }
        .padding(.top, 4)
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications to Blacklist"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.begin { resp in
            guard resp == .OK else { return }
            var newIds = settings.blacklistBundleIds
            for url in panel.urls {
                if let bid = Bundle(url: url)?.bundleIdentifier {
                    if !newIds.contains(bid) {
                        newIds.append(bid)
                    }
                }
            }
            settings.blacklistBundleIds = newIds
        }
    }

    private func removeSelected() {
        let toRemove = selection
        selection.removeAll()
        settings.blacklistBundleIds.removeAll { toRemove.contains($0) }
    }

    private func appDisplayName(for bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            if let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String {
                return name
            }
            let disp = FileManager.default.displayName(atPath: url.path)
            return disp.replacingOccurrences(of: ".app", with: "")
        }
        return bundleId
    }
}

private struct AppIconView: View {
    let bundleId: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .foregroundColor(.secondary)
        }
    }
}
