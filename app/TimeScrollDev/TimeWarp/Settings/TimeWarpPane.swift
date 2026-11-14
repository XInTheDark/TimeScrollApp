import AppKit
import SwiftUI

/// Settings ▸ Time Warp.
struct TimeWarpPane: View {
  @ObservedObject var settings: SettingsStore
  @AppStorage(TimeWarpSettings.enabledKey) private var isEnabled = true
  @AppStorage(TimeWarpSettings.recordsOpenItemsKey) private var recordsOpenItems = false
  @AppStorage(TimeWarpSettings.warpPointShortcutKey) private var warpPointShortcut = true
  @StateObject private var automation = TimeWarpAutomationModel()
  @State private var accessibilityGranted = Permissions.isAccessibilityGranted()

  var body: some View {
    SettingsPaneScrollView {
      SettingsSectionCard(
        title: "Time Warp",
        subtitle: "Reopen the pages, files and folders you were using at any time on your timeline."
      ) {
        Toggle("Record Time Warp", isOn: notifying($isEnabled))
        if isEnabled && !accessibilityGranted {
          HStack(spacing: 8) {
            Label("Time Warp needs Accessibility access.", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            Button("Open Settings…") { Permissions.requestAccessibility() }
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Record everything that’s open", isOn: notifying($recordsOpenItems))
          Text("Also records tabs and documents open in the background, not just the one in front.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Add Warp points with ⌃⌥⌘W", isOn: notifying($warpPointShortcut))
        if !settings.vaultEnabled {
          Text("Time Warp records are kept unencrypted while the vault is off.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      if recordsOpenItems {
        SettingsSectionCard(
          title: "Tabs and Windows",
          subtitle: "Allow these apps so Time Warp can list their open tabs and windows."
        ) {
          TimeWarpAutomationList(model: automation)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      let granted = Permissions.isAccessibilityGranted()
      guard granted != accessibilityGranted else { return }
      accessibilityGranted = granted
      // Recording waits for Accessibility; start it now rather than at the next capture restart.
      NotificationCenter.default.post(name: TimeWarpSettings.didChangeNotification, object: nil)
    }
  }

  private func notifying(_ binding: Binding<Bool>) -> Binding<Bool> {
    Binding(
      get: { binding.wrappedValue },
      set: {
        binding.wrappedValue = $0
        NotificationCenter.default.post(name: TimeWarpSettings.didChangeNotification, object: nil)
      })
  }
}
