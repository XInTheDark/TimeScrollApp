import SwiftUI

/// Offers Time Warp during setup.
struct TimeWarpOnboardingCard: View {
  @Binding var isEnabled: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 24))
        .foregroundStyle(.teal)
        .frame(width: 32)
      VStack(alignment: .leading, spacing: 4) {
        Text("Time Warp")
          .font(.headline)
        Text("Reopen the pages, files and folders you were using at any time on your timeline.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Toggle("", isOn: $isEnabled)
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel("Time Warp")
    }
    .padding(16)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }

  /// Saves the choice made during setup.
  static func apply(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
    guard TimeWarpSettings.isEnabled(defaults) != isEnabled else { return }
    defaults.set(isEnabled, forKey: TimeWarpSettings.enabledKey)
    NotificationCenter.default.post(name: TimeWarpSettings.didChangeNotification, object: nil)
  }
}
