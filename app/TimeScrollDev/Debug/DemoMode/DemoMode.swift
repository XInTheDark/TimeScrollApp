#if DEBUG
import Foundation

/// Debug-only mode that shows curated fake data for marketing screenshots. See `scripts/marketing/`.
///
/// It only turns on for a build with the marketing bundle id running under a fake home folder, so
/// it can't read or write anyone's real TimeScroll data.
enum DemoMode {
  static let bundleIdSuffix = ".marketing"
  static let summaryModels = ["lfm3"]

  static let isActive = isAllowed(bundleId: Bundle.main.bundleIdentifier,
                                  environment: ProcessInfo.processInfo.environment,
                                  home: NSHomeDirectory())

  static func isAllowed(bundleId: String?, environment: [String: String], home: String) -> Bool {
    guard bundleId?.hasSuffix(bundleIdSuffix) == true,
          environment["TIMESCROLL_DEMO_SCENE"] != nil,
          let fakeHome = environment["CFFIXED_USER_HOME"] else { return false }
    return !fakeHome.isEmpty && home == fakeHome
  }

  /// Shown instead of the build folder wherever the app displays its own location.
  static let installedAppURL = URL(fileURLWithPath: "/Applications/TimeScroll.app", isDirectory: true)

  static var sceneName: String { ProcessInfo.processInfo.environment["TIMESCROLL_DEMO_SCENE"] ?? "" }
  static var scriptDir: URL { environmentURL("TIMESCROLL_DEMO_DATA") }
  static var outputDir: URL { environmentURL("TIMESCROLL_DEMO_OUTPUT") }

  private static func environmentURL(_ key: String) -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment[key] ?? "", isDirectory: true)
  }
}
#endif
