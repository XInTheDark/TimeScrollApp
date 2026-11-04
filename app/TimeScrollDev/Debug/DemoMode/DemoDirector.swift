#if DEBUG
import AppKit
import SwiftUI

/// Runs one scene: sets the app up, waits for it to settle, and tells the screenshot script which
/// window to capture by writing `<scene>.ready`.
@MainActor
final class DemoDirector {
  static let shared = DemoDirector()

  enum Scene: String {
    case seed, timeline, calendar, audio, searchText, searchAI, summary, appTime, export
    case privacy, vault, general, mcp
  }

  private let scene = Scene(rawValue: DemoMode.sceneName)
  private var paneWindow: NSWindow?

  func start(showMainWindow: () -> Void) {
    NSApp.setActivationPolicy(.regular)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    switch scene {
    case .seed: runSeed()
    case .export: presentExport()
    case .privacy: present(pane: PrivacyPane(settings: SettingsStore.shared))
    case .vault: present(pane: LockedView(), size: NSSize(width: 860, height: 520))
    case .general: present(pane: GeneralPane(settings: SettingsStore.shared))
    case .mcp:
      UserDefaults.standard.set(true, forKey: "settings.mcpEnabled")
      present(pane: MCPSettingsPane())
    case .timeline, .calendar, .audio, .searchText, .searchAI, .summary, .appTime: showMainWindow()
    case nil: break
    }
  }

  func timelineAppeared(timeline: TimelineModel, selection: TimelineRangeSelection, search: @escaping (String) -> Void) async {
    NSLog("[Demo] timeline appeared, scene=%@", DemoMode.sceneName)
    var found = mainWindow
    for _ in 0..<50 where found == nil {
      try? await Task.sleep(for: .milliseconds(100))
      found = mainWindow
    }
    guard let scene, let window = found else {
      NSLog("[Demo] no main window: %@", NSApp.windows.map { "\($0.title)|\($0.isVisible)" }.description)
      return
    }
    window.setContentSize(NSSize(width: 1440, height: 900))
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    await waitUntilLoaded(timeline)
    switch scene {
    case .timeline:
      zoomIn(timeline)
      show(screen: "preview-sales", in: nil, timeline: timeline)
    case .audio:
      zoomIn(timeline)
      if let index = timeline.metas.firstIndex(where: { $0.captureKind == .audio }) { timeline.selectedIndex = index }
    case .searchText:
      SettingsStore.shared.aiModeOn = false
      search("Lisbon")
    case .searchAI:
      SettingsStore.shared.aiModeOn = true
      search("that chart with sales by region")
    case .summary: await selectAndSummarize(.yesterday, screen: "preview-sales", timeline: timeline, selection: selection)
    case .appTime: await selectAndSummarize(.lastWeek, screen: "xcode-checkout", timeline: timeline, selection: selection)
    case .calendar:
      zoomIn(timeline)
      show(screen: "xcode-checkout", in: nil, timeline: timeline)
      timeline.dayCalendar.present(showing: Calendar.current.date(byAdding: .day, value: -14, to: Date()))
    default: return
    }
    reportReady(window: window)
  }

  /// So the loaded days fill the timeline's width. Relative to the first launch's zoom, because
  /// the zoom is a saved setting.
  private func zoomIn(_ timeline: TimelineModel) {
    let key = "demo.baseMsPerPoint"
    let defaults = UserDefaults.standard
    if defaults.double(forKey: key) == 0 { defaults.set(timeline.msPerPoint, forKey: key) }
    timeline.msPerPoint = defaults.double(forKey: key) * 0.55
  }

  private func waitUntilLoaded(_ timeline: TimelineModel) async {
    try? await Task.sleep(for: .milliseconds(300))
    for _ in 0..<100 where timeline.isLoading || timeline.metas.isEmpty {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Selects the newest capture of a screen. Changing the selection also refits the image to the
  /// stage, which doesn't happen on its own after a resize or when the summary panel opens.
  private func show(screen: String, in range: TimelineRange?, timeline: TimelineModel) {
    let index = timeline.metas.firstIndex { meta in
      guard meta.path.contains("/\(screen).") else { return false }
      guard let range else { return true }
      return meta.startedAtMs >= range.fromMs && meta.startedAtMs < range.toMs
    }
    if let index { timeline.selectedIndex = index }
  }

  private var mainWindow: NSWindow? {
    NSApp.windows.first { $0.title == "TimeScroll" && $0.canBecomeMain }
  }

  private func selectAndSummarize(_ preset: TimelineRangePreset, screen: String, timeline: TimelineModel, selection: TimelineRangeSelection) async {
    guard let range = preset.range(now: Date(), calendar: .current) else { return }
    selection.begin()
    selection.select(range)
    timeline.reveal(range)
    try? await Task.sleep(for: .seconds(1.5))
    selection.requestSummary()
    try? await Task.sleep(for: .seconds(1))
    show(screen: screen, in: range, timeline: timeline)
  }

  private func runSeed() {
    do {
      let url = DemoMode.scriptDir.appendingPathComponent("manifest.json")
      let manifest = try JSONDecoder().decode(DemoManifest.self, from: Data(contentsOf: url))
      applySettings(manifest)
      try DemoSeeder.seed(manifest: manifest, dataDir: DemoMode.scriptDir)
      SettingsStore.shared.flush()
      UserDefaults.standard.synchronize()
      writeReady(windowNumber: 0)
    } catch {
      fail(error)
    }
  }

  private func applySettings(_ manifest: DemoManifest) {
    let settings = SettingsStore.shared
    settings.aiEmbeddingsEnabled = true
    settings.aiModeOn = true
    settings.audioFeatureEnabled = true
    settings.textProcessingMode = .accessibility
    settings.blacklistBundleIds = manifest.excludedBundleIds
    settings.defaultSummaryModel = DemoMode.summaryModels[0]
    let defaults = UserDefaults.standard
    defaults.set("tiles", forKey: "settings.searchViewMode")
    defaults.set(DemoMode.summaryModels[0], forKey: RangeSummaryServices.modelKey)
    defaults.set(true, forKey: AppDelegate.summarySetupShownKey)
  }

  private func presentExport() {
    let controller = TimelapseExportWindowController.shared
    if let range = TimelineRangePreset.lastWeek.range(now: Date(), calendar: .current) {
      controller.present(range: range)
    } else {
      controller.present()
    }
    mainWindow?.orderOut(nil)
    if let window = controller.window { reportReady(window: window) }
  }

  private func present<Pane: View>(pane: Pane, size: NSSize? = NSSize(width: 860, height: 620)) {
    mainWindow?.orderOut(nil)
    let hosting = NSHostingController(rootView: pane.environmentObject(SettingsStore.shared))
    let window = NSWindow(contentViewController: hosting)
    if let size { window.setContentSize(size) }
    window.title = "Settings"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    paneWindow = window
    reportReady(window: window)
  }

  private func reportReady(window: NSWindow) {
    let settle = Double(ProcessInfo.processInfo.environment["TIMESCROLL_DEMO_SETTLE"] ?? "") ?? 4
    Task {
      try? await Task.sleep(for: .seconds(settle))
      // Drawn as the active window with nothing focused, whatever else happened during the wait.
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      window.makeFirstResponder(nil)
      try? await Task.sleep(for: .milliseconds(700))
      self.writeReady(windowNumber: window.windowNumber)
    }
  }

  private func writeReady(windowNumber: Int) {
    let file = DemoMode.outputDir.appendingPathComponent("\(DemoMode.sceneName).ready")
    try? "\(windowNumber)".write(to: file, atomically: true, encoding: .utf8)
  }

  private func fail(_ error: Error) {
    let file = DemoMode.outputDir.appendingPathComponent("\(DemoMode.sceneName).failed")
    try? "\(error)".write(to: file, atomically: true, encoding: .utf8)
  }
}

#endif
