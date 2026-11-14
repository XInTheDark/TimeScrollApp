import AppKit
import Foundation
import UniformTypeIdentifiers

/// Decides how an item is reopened, right before opening. Files open in the app they were open in.
/// Programs are never launched, and a script with no recorded app is refused, since its default app
/// may run it.
enum TimeWarpOpenSafety {
  enum Verdict: Equatable {
    case web(URL)
    /// A document, opened in `app` when given.
    case file(URL, app: URL?)
    case folder(URL)
    case app(URL)
    case missing
    case refused
  }

  static func check(_ item: TimeWarpPlanItem,
                    appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> Verdict {
    switch item.kind {
    case .page:
      guard let url = URL(string: item.value), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https" else { return .refused }
      return .web(url)
    case .app:
      return appURL(item.value).map(Verdict.app) ?? .missing
    case .warpPoint:
      return .refused
    case .document, .folder:
      let url = URL(fileURLWithPath: item.value)
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
      guard let values else { return .missing }
      if values.isDirectory == true && values.isPackage != true { return .folder(url) }
      let type = values.contentType ?? .data
      if type.conforms(to: .application) || type.conforms(to: .executable) { return .refused }
      let app = item.appBundleId.flatMap(appURL)
      if app == nil && type.conforms(to: .script) { return .refused }
      return .file(url, app: app)
    }
  }
}
