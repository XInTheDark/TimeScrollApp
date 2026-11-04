import SwiftUI

/// Shown once to people who finished setup before background summaries existed.
struct SummarySetupView: View {
  @ObservedObject var settings: SettingsStore
  let onDone: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Better Summaries")
          .font(.title2.weight(.semibold))
        Text("Summarizing each finished day with a local Ollama model makes week and month summaries more detailed.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      SummarySetupControls(settings: settings)
      HStack {
        Spacer()
        Button("Done", action: onDone)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 480)
  }
}
