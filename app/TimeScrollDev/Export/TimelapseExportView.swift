import SwiftUI

struct TimelapseExportView: View {
  @ObservedObject var model: TimelapseExportModel

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Export Timelapse").font(.title2.bold())
      Form {
        LabeledContent("From") { ExportDatePicker(date: $model.options.start).accessibilityLabel("Start date and time") }
        LabeledContent("To") { ExportDatePicker(date: $model.options.end).accessibilityLabel("End date and time") }
        Picker("Resolution", selection: $model.options.quality) {
          ForEach(TimelapseOptions.Quality.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Date and time", selection: $model.options.timestamp) {
          ForEach(TimelapseOptions.Timestamp.allCases) { Text($0.rawValue).tag($0) }
        }
        Toggle("Match real time", isOn: $model.options.matchRealTime)
        if model.options.matchRealTime {
          Picker("Speed", selection: $model.options.speed) {
            ForEach([1.0, 10, 30, 60, 120, 300, 600], id: \.self) { Text("\(Int($0))×").tag($0) }
          }
        }
      }
      .disabled(model.isExporting)

      Text(model.options.matchRealTime
           ? "Keeps recorded intervals proportional at the selected speed. Time when recording was stopped is skipped."
           : "Shows 30 snapshots per second, regardless of time between captures.")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if model.isExporting {
        ProgressView(value: model.progress) {
          Text(model.progress == 0 ? "Preparing snapshots…" : "Exporting… \(Int(model.progress * 100))%")
        }
      }
      if let message = model.message {
        Text(message).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if let url = model.exportedURL {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Spacer()
        if model.isExporting {
          Button("Cancel Export", role: .cancel) { model.cancel() }
        } else {
          Button("Export…") { model.export() }
            .keyboardShortcut(.defaultAction)
            .disabled(model.options.end <= model.options.start)
        }
      }
    }
    .padding(24)
    .frame(minWidth: 440, idealWidth: 480)
  }
}
