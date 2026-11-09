import ApplicationServices
import CoreGraphics
import Foundation

protocol PrivateWindowEvidenceReading: Sendable {
  /// Evidence for each Accessibility window of `pid`. `addressFieldWindows` lists the windows whose
  /// address field should also be read, because walking the toolbar costs more than the title.
  func evidence(pid: pid_t, profile: PrivateBrowsingProfile,
                addressFieldWindows: Set<CGWindowID>) -> [CGWindowID: PrivateWindowEvidence]
}

/// Reads browser windows over Accessibility, bounded so a hung browser cannot stall detection.
struct LivePrivateWindowEvidenceReader: PrivateWindowEvidenceReading {
  private static let messagingTimeout: Float = 0.25
  private static let maxWindows = 64
  private static let maxToolbarNodes = 4000
  private static let maxToolbarDepth = 14
  private static let toolbarWalkSeconds: TimeInterval = 0.2

  private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  /// `_AXUIElementGetWindow` is private API, the only exact link from an Accessibility window to a
  /// CG window id. Frames cannot tell stacked windows apart. Without it nothing is classified.
  private static let getWindow: GetWindowFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: GetWindowFunction.self)
  }()

  static var canIdentifyWindows: Bool { getWindow != nil }

  func evidence(pid: pid_t, profile: PrivateBrowsingProfile,
                addressFieldWindows: Set<CGWindowID>) -> [CGWindowID: PrivateWindowEvidence] {
    guard let getWindow = Self.getWindow else { return [:] }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
    guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [:] }

    var result: [CGWindowID: PrivateWindowEvidence] = [:]
    for window in windows.prefix(Self.maxWindows) {
      AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
      var id: CGWindowID = 0
      guard getWindow(window, &id) == .success, id != 0 else { continue }
      var evidence = PrivateWindowEvidence(
        title: attribute(window, kAXTitleAttribute) as? String,
        subrole: attribute(window, kAXSubroleAttribute) as? String,
        hasCloseButton: attribute(window, kAXCloseButtonAttribute) != nil)
      if let rule = profile.addressField, addressFieldWindows.contains(id),
         !PrivateWindowClassifier.hasMarker(evidence, profile: profile) {
        evidence.addressFieldDescription = addressFieldDescription(in: window, rule: rule)
      }
      result[id] = evidence
    }
    return result
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }

  /// Only browser chrome is searched. Page content can say anything, and is skipped.
  private func addressFieldDescription(in window: AXUIElement, rule: PrivateBrowsingProfile.AddressFieldRule) -> String? {
    var visited = 0
    let deadline = ProcessInfo.processInfo.systemUptime + Self.toolbarWalkSeconds

    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
      visited += 1
      guard visited <= Self.maxToolbarNodes, depth <= Self.maxToolbarDepth,
            ProcessInfo.processInfo.systemUptime < deadline else { return nil }
      AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
      if attribute(element, kAXIdentifierAttribute) as? String == rule.identifier { return element }
      if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" { return nil }
      for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = find(child, depth: depth + 1) { return found }
      }
      return nil
    }
    return find(window, depth: 0).flatMap { attribute($0, kAXDescriptionAttribute) as? String }
  }
}
