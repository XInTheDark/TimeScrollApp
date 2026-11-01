import SwiftUI

/// Preferences ▸ Search: grouping results into activity sessions, and how sessions are split.
struct SearchSessionsSection: View {
  @ObservedObject var settings: SettingsStore

  var body: some View {
    SettingsSectionCard(
      title: "Sessions",
      subtitle: "A session is a stretch of related work, even across apps. It ends after 15 minutes idle or when what's on screen changes."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Toggle("Group search results into sessions", isOn: $settings.searchGroupsSessions)

        LabeledContent("Splitting") {
          Picker("", selection: $settings.sessionSensitivity) {
            ForEach(SessionSensitivity.allCases) { sensitivity in
              Text(sensitivity.displayName).tag(sensitivity)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(maxWidth: 280)
        }

        Text(sensitivityDescription)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var sensitivityDescription: String {
    switch settings.sessionSensitivity {
    case .lenient: return "Fewer, longer sessions: only a clear change of task starts a new one."
    case .balanced: return "Starts a new session when you move on to different work."
    case .strict: return "More, shorter sessions: smaller changes in what you're looking at start a new one."
    }
  }
}
