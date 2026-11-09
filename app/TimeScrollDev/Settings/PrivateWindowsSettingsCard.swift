import AppKit
import SwiftUI

/// The private browser window setting. Turning it on explains its limits first.
struct PrivateWindowsSettingsCard: View {
  @ObservedObject var settings: SettingsStore
  @State private var showsEnableInfo = false
  @State private var accessibilityGranted = Permissions.isAccessibilityGranted()

  var body: some View {
    SettingsSectionCard(
      title: "Private Browser Windows",
      subtitle: "Leave incognito and private windows out of recordings."
    ) {
      Toggle("Exclude private browser windows", isOn: toggleBinding)

      if settings.excludePrivateWindows && !accessibilityGranted {
        HStack(spacing: 10) {
          Label("Turn on Accessibility for TimeScroll. Private windows are being recorded until you do.",
                systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)

          Spacer(minLength: 0)

          Button("Open Settings…") {
            Permissions.requestAccessibility()
          }
        }
      }
    }
    .alert("Exclude private browser windows?", isPresented: $showsEnableInfo) {
      Button("Turn On") { enable() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.enableInfo)
    }
    .onAppear(perform: refreshAccessibility)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshAccessibility()
    }
    .onChange(of: settings.excludePrivateWindows) { _, _ in
      Task { @MainActor in
        await AppState.shared.captureManager.refreshExclusions()
      }
    }
  }

  static let enableInfo = """
    This isn't 100% reliable. It should work in major browsers like Chrome, Brave and Firefox, but \
    results may vary, so open a private window and check your timeline to try it yourself.

    Other windows in that browser may lose their menus and popups in recordings while a private \
    window is open. Sound from private windows is still recorded if system audio is on.

    TimeScroll needs Accessibility permission to detect these windows.
    """

  private var toggleBinding: Binding<Bool> {
    Binding(
      get: { settings.excludePrivateWindows },
      set: { isOn in
        if isOn {
          showsEnableInfo = true
        } else {
          settings.excludePrivateWindows = false
        }
      }
    )
  }

  private func enable() {
    settings.excludePrivateWindows = true
    refreshAccessibility()
    if !accessibilityGranted { Permissions.requestAccessibility() }
  }

  private func refreshAccessibility() {
    accessibilityGranted = Permissions.isAccessibilityGranted()
  }
}
