import AppKit
import CoreServices
import Foundation

/// Apple Events for Time Warp: permission checks and scripts. Scripts only run against an app that
/// is running (each one checks `is running` first, so it never launches the app), give up after two
/// seconds, and never prompt. The permission prompt appears only when the user asks for it in Settings.
/// Not thread-safe: call from one serial queue.
final class TimeWarpAppleEvents {
  enum Permission: Equatable {
    case allowed
    case needsConsent
    case denied
    case notRunning
    case unknown
  }

  /// Apps whose contents Time Warp can list over Apple Events. Browsers whose private windows can't
  /// be told apart are never read, so they aren't offered.
  static let supportedBundleIds: [String] = [
    "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi", "com.apple.Safari", TimeWarpBrowserCatalog.finderBundleId, TimeWarpBrowserCatalog.iTermBundleId,
  ].filter { PrivateBrowsingCatalog.profile(forBundleId: $0).map { $0.verification == .liveTested } ?? true }

  private var compiled: [String: NSAppleScript] = [:]

  static func permission(bundleId: String, askUser: Bool) -> Permission {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    guard let desc = target.aeDesc else { return .unknown }
    let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
    switch status {
    case noErr: return .allowed
    case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
    case OSStatus(errAEEventNotPermitted): return .denied
    case OSStatus(procNotFound): return .notRunning
    default: return .unknown
    }
  }

  /// Runs `body` inside a `tell` to the app, only if it is running and allowed.
  func run(bundleId: String, body: String, timeoutSeconds: Int = 2) -> NSAppleEventDescriptor? {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty,
          Self.permission(bundleId: bundleId, askUser: false) == .allowed else { return nil }
    let source = """
    with timeout of \(timeoutSeconds) seconds
      if application id "\(bundleId)" is running then
        tell application id "\(bundleId)"
          \(body)
        end tell
      end if
    end timeout
    """
    let script: NSAppleScript
    if let cached = compiled[source] {
      script = cached
    } else {
      guard let made = NSAppleScript(source: source) else { return nil }
      var error: NSDictionary?
      guard made.compileAndReturnError(&error) else { return nil }
      if compiled.count > 32 { compiled.removeAll() }
      compiled[source] = made
      script = made
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    return error == nil ? result : nil
  }

  // MARK: Reading results

  static func list(_ descriptor: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
    guard let descriptor, descriptor.numberOfItems > 0 else { return [] }
    return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
  }

  static func strings(_ descriptor: NSAppleEventDescriptor?) -> [String?] {
    list(descriptor).map { $0.descriptorType == typeType ? nil : $0.stringValue }
  }
}
