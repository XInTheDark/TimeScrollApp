import AppKit
import SwiftUI

/// One row per supported app, with its permission and the button that asks for it.
struct TimeWarpAutomationList: View {
  @ObservedObject var model: TimeWarpAutomationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.apps) { app in
        HStack(spacing: 8) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
            .resizable()
            .frame(width: 20, height: 20)
          Text(app.name)
          Spacer(minLength: 8)
          status(app)
        }
      }
      if model.apps.contains(where: { $0.permission == .denied }) {
        Button("Open Automation Settings…") { Permissions.open(.automation) }
          .buttonStyle(.link)
      }
    }
    .onAppear { model.reload() }
  }

  @ViewBuilder
  private func status(_ app: TimeWarpAutomationModel.App) -> some View {
    switch app.permission {
    case .allowed:
      Label("Allowed", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .needsConsent:
      Button("Allow…") { model.ask(app) }
        .disabled(model.askingBundleId != nil)
    case .denied:
      Text("Not allowed")
        .foregroundStyle(.secondary)
    case .notRunning:
      Button("Open \(app.name) to Allow") { model.launch(app) }
    case .unknown:
      Text("Unavailable")
        .foregroundStyle(.secondary)
    }
  }
}
