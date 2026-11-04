import AppKit
import SwiftUI

/// What a time range held: time per app, and a text summary from the local model.
struct RangeSummaryPanel: View {
  @ObservedObject var model: RangeSummaryPanelModel
  let title: String
  /// The stats and summary cover everything in the range, even when filters narrow the timeline.
  let isTimelineFiltered: Bool
  let onClose: () -> Void

  static let width: CGFloat = 340

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          AppTimeSection(stats: model.stats)
          summarySection
          if isTimelineFiltered {
            Text("Includes all apps, not only your filters.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: Self.width)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.headline)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Close")
      .accessibilityLabel("Close summary")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var summarySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Summary").font(.subheadline.weight(.semibold))
        Spacer(minLength: 4)
        modelMenu
      }
      summaryBody
    }
  }

  @ViewBuilder
  private var modelMenu: some View {
    if case .loaded(let names) = model.models, !names.isEmpty {
      Menu(model.selectedModel ?? "Choose Model") {
        ForEach(names, id: \.self) { name in
          Button {
            model.select(model: name)
          } label: {
            if name == model.selectedModel {
              Label(name, systemImage: "checkmark")
            } else {
              Text(name)
            }
          }
        }
      }
      .menuStyle(.borderlessButton)
      .controlSize(.small)
      .frame(maxWidth: 190, alignment: .trailing)
      .help("The Ollama model that writes summaries")
    }
  }

  @ViewBuilder
  private var summaryBody: some View {
    switch model.summary {
    case .idle:
      Button("Summarize") { model.regenerate() }
    case .generating:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Summarizing…").foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Button("Cancel") { model.cancelGenerating() }
          .controlSize(.small)
      }
    case .text(let text, let savedModel, let createdAtMs, let isOutdated):
      RangeSummaryText(text: text)
      Text(caption(savedModel: savedModel, createdAtMs: createdAtMs, isOutdated: isOutdated))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
          model.regenerate()
        } label: {
          Label("Regenerate", systemImage: "arrow.clockwise")
        }
      }
      .controlSize(.small)
    case .problem(let problem):
      problemView(problem)
    }
  }

  private func caption(savedModel: String?, createdAtMs: Int64?, isOutdated: Bool) -> String {
    guard let savedModel, let createdAtMs else { return "Not saved. Only finished days, weeks, months and years are saved." }
    let date = Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000)
    let made = "Made with \(savedModel), \(date.formatted(date: .abbreviated, time: .shortened))"
    return isOutdated ? "\(made). Out of date. Regenerate to update it." : made
  }

  private func problemView(_ problem: RangeSummaryPanelModel.Problem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(Self.message(for: problem))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if Self.canRetry(problem) {
        Button("Try Again") { model.retry() }
          .controlSize(.small)
      }
    }
  }

  static func message(for problem: RangeSummaryPanelModel.Problem) -> String {
    switch problem {
    case .ollamaUnavailable: return "Ollama isn’t running. Open Ollama, then try again."
    case .noModels: return "Ollama has no text models. Install one with “ollama pull”, then try again."
    case .chooseModel: return "Choose a model above, then try again."
    case .modelNotInstalled: return "This model is no longer installed. Choose another."
    case .modelUnsuitable: return "This model can’t write summaries. Choose another."
    case .cloudModelRefused: return "This model runs in the cloud, so it can’t be used for your screen text. Choose another."
    case .failed: return "The summary couldn’t be finished."
    case .discarded: return "Snapshots in this range changed while summarizing."
    case .noActivity: return "There’s no screen activity to summarize in this range."
    case .vaultLocked: return "Unlock the vault to summarize."
    }
  }

  private static func canRetry(_ problem: RangeSummaryPanelModel.Problem) -> Bool {
    switch problem {
    case .noActivity, .vaultLocked: return false
    default: return true
    }
  }
}
