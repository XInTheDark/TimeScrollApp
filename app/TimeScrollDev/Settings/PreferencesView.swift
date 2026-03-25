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
            SecurityPane(settings: settings)
                .tabItem { Label("Security", systemImage: "lock") }
            SearchPane(settings: settings)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            MCPSettingsPane()
                .tabItem { Label("MCP", systemImage: "bolt.horizontal") }
            StoragePane(settings: settings)
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            UpdatesPane(settings: settings)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            StatsPane()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 520, idealHeight: 560)
        .onDisappear { settings.flush() }
    }
}

struct SettingsPaneScrollView<Content: View>: View {
    private let alignment: HorizontalAlignment
    private let content: Content

    init(alignment: HorizontalAlignment = .leading, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: alignment, spacing: 18) {
                    content
                }
                .frame(width: SettingsPaneLayout.maxContentWidth, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .settingsInsetCard(padding: 18)
    }
}

private enum SettingsPaneLayout {
    static let maxContentWidth: CGFloat = 720
}

private struct SettingsInsetCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
            )
    }
}

extension View {
    func settingsInsetCard(padding: CGFloat = 16) -> some View {
        modifier(SettingsInsetCardModifier(padding: padding))
    }
}
