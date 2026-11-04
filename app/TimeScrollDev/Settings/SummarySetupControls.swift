import SwiftUI

/// The background summary preference and default model, used in setup and in Preferences.
struct SummarySetupControls: View {
  @ObservedObject var settings: SettingsStore
  @StateObject private var models = SummaryModelList()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Summarize finished days in the background", isOn: $settings.backgroundSummariesEnabled)

      LabeledContent("Default summary model") {
        Picker("", selection: $settings.defaultSummaryModel) {
          Text("None").tag("")
          ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 240)
      }

      if let status {
        HStack(spacing: 8) {
          Text(status)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if models.state == .ollamaUnavailable {
            Button("Retry") { models.refresh() }
              .controlSize(.small)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear { models.refresh() }
  }

  private var choices: [String] {
    var names: [String] = []
    if case .loaded(let listed) = models.state { names = listed }
    let selected = settings.defaultSummaryModel
    if !selected.isEmpty, !names.contains(selected) { names.append(selected) }
    return names
  }

  private var status: String? {
    switch models.state {
    case .loading:
      return nil
    case .ollamaUnavailable:
      return "Ollama isn't running."
    case .loaded(let listed) where listed.isEmpty:
      return "No text models are installed in Ollama."
    case .loaded:
      return settings.backgroundSummariesEnabled && settings.defaultSummaryModel.isEmpty
        ? "Choose a model to turn this on."
        : nil
    }
  }
}
