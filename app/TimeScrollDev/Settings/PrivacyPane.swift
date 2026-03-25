import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PrivacyPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var selection = Set<String>()

    var body: some View {
        SettingsPaneScrollView {
            SettingsSectionCard(
                title: "Blacklisted Apps",
                subtitle: "Windows from these apps are excluded from capture whenever they are visible."
            ) {
                Group {
                    if settings.blacklistBundleIds.isEmpty {
                        emptyState
                    } else {
                        appList
                    }
                }

                HStack(spacing: 10) {
                    Text(selectionSummary)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: addApps) {
                        Label("Add App…", systemImage: "plus")
                    }

                    Button(role: .destructive, action: removeSelected) {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .onChange(of: settings.blacklistBundleIds) { newList in
            Task { @MainActor in
                await AppState.shared.captureManager.updateExclusions(with: newList)
            }
        }
    }

    private var appList: some View {
        List(selection: $selection) {
            ForEach(settings.blacklistBundleIds, id: \.self) { bid in
                HStack(spacing: 10) {
                    AppIconView(bundleId: bid)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appDisplayName(for: bid))
                        Text(bid)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .tag(bid)
            }
        }
        .frame(minHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.secondary)

            Text("No apps excluded")
                .font(.headline)

            Text("Add an app here if you never want its windows to be captured.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
        )
    }

    private var selectionSummary: String {
        if selection.isEmpty {
            let count = settings.blacklistBundleIds.count
            return count == 1 ? "1 app excluded from capture" : "\(count) apps excluded from capture"
        }

        let count = selection.count
        return count == 1 ? "1 app selected" : "\(count) apps selected"
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
