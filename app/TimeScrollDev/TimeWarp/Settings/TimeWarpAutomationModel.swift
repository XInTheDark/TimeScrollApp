import AppKit
import Foundation

/// Which installed apps let Time Warp list their tabs and windows, and asking for that permission.
@MainActor
final class TimeWarpAutomationModel: ObservableObject {
  struct App: Identifiable, Equatable {
    let bundleId: String
    let name: String
    let url: URL
    var permission: TimeWarpAppleEvents.Permission
    var id: String { bundleId }
  }

  @Published private(set) var apps: [App] = []
  @Published private(set) var askingBundleId: String?
  private var activationToken: NSObjectProtocol?

  init() {
    // Permissions change in System Settings; recheck when the user comes back.
    activationToken = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  deinit {
    if let activationToken { NotificationCenter.default.removeObserver(activationToken) }
  }

  func reload() {
    let installed: [(String, URL)] = TimeWarpAppleEvents.supportedBundleIds.compactMap { bundleId in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { (bundleId, $0) }
    }
    Task {
      let checked = await Task.detached(priority: .userInitiated) {
        installed.map { bundleId, url in
          App(bundleId: bundleId, name: Self.name(of: url), url: url,
              permission: TimeWarpAppleEvents.permission(bundleId: bundleId, askUser: false))
        }
      }.value
      apps = checked
    }
  }

  /// Shows the system prompt for one app. The app must be running.
  func ask(_ app: App) {
    guard askingBundleId == nil else { return }
    askingBundleId = app.bundleId
    let bundleId = app.bundleId
    Task {
      let permission = await Task.detached(priority: .userInitiated) {
        TimeWarpAppleEvents.permission(bundleId: bundleId, askUser: true)
      }.value
      askingBundleId = nil
      if let index = apps.firstIndex(where: { $0.bundleId == bundleId }) { apps[index].permission = permission }
      NotificationCenter.default.post(name: TimeWarpSettings.didChangeNotification, object: nil)
    }
  }

  func launch(_ app: App) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { [weak self] _, _ in
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        self?.reload()
      }
    }
  }

  nonisolated private static func name(of url: URL) -> String {
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }
}
