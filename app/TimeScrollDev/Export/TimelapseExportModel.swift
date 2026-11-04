import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TimelapseExportModel: ObservableObject {
  @Published var options = TimelapseOptions()
  @Published private(set) var isExporting = false
  @Published private(set) var progress = 0.0
  @Published private(set) var message: String?
  @Published private(set) var exportedURL: URL?
  private var task: Task<Void, Never>?
  private var worker: Task<TimelapseExportResult, Error>?

  func export() {
    guard !isExporting else { return }
    guard options.end > options.start else {
      message = TimelapseError.invalidRange.localizedDescription
      return
    }
    let panel = NSSavePanel()
    panel.title = "Export Timelapse"
    panel.allowedContentTypes = [.quickTimeMovie]
    panel.nameFieldStringValue = "TimeScroll Timelapse.mov"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    start(destination: url)
  }

  func start(destination: URL) {
    guard !isExporting else { return }
    let options = options
    isExporting = true
    progress = 0
    message = nil
    exportedURL = nil
    let update: @Sendable (Double) -> Void = { [weak self] value in
      guard let self else { return }
      Task { @MainActor in self.progress = value }
    }
    let worker = Task.detached(priority: .userInitiated) {
      try await TimelapseExporter.export(options: options, destination: destination, progress: update)
    }
    self.worker = worker
    task = Task { [weak self] in
      do {
        let result = try await worker.value
        self?.exportedURL = destination
        self?.message = result.message
      } catch is CancellationError {
        self?.message = "Export cancelled."
      } catch {
        self?.message = error.localizedDescription
      }
      self?.isExporting = false
      self?.worker = nil
      self?.task = nil
    }
  }

  func cancel() { worker?.cancel() }
}
