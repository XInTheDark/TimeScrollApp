import ApplicationServices
import Foundation

/// What Accessibility reports about one window, read with short timeouts so a hung app costs at
/// most a fraction of a second.
struct TimeWarpWindowFacts {
  let element: AXUIElement
  let title: String?
  let subrole: String?
  let hasCloseButton: Bool
  let document: String?
}

enum TimeWarpWindowReader {
  static let messagingTimeout: Float = 0.1
  /// Budget for finding a page's web area (Safari, Firefox): about 40–60 nodes in practice.
  static let webAreaDeadline: TimeInterval = 0.25
  static let webAreaMaxNodes = 600
  static let maxWindows = 64

  static func appElement(pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, messagingTimeout)
    return app
  }

  static func focusedWindow(pid: pid_t) -> AXUIElement? {
    guard let value = attribute(appElement(pid: pid), kAXFocusedWindowAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  static func windows(pid: pid_t) -> [AXUIElement] {
    (attribute(appElement(pid: pid), kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(maxWindows).map { $0 }
  }

  static func facts(of window: AXUIElement) -> TimeWarpWindowFacts {
    AXUIElementSetMessagingTimeout(window, messagingTimeout)
    return TimeWarpWindowFacts(element: window,
                               title: attribute(window, kAXTitleAttribute) as? String,
                               subrole: attribute(window, kAXSubroleAttribute) as? String,
                               hasCloseButton: attribute(window, kAXCloseButtonAttribute) != nil,
                               document: stringValue(attribute(window, kAXDocumentAttribute)))
  }

  /// The address of the page shown in `window`: breadth-first to the first web area, bounded by
  /// time and node count. Returns nil if none is found in budget (a page still loading).
  static func webAreaURL(in window: AXUIElement) -> String? {
    let deadline = ProcessInfo.processInfo.systemUptime + webAreaDeadline
    var queue = [window]
    var index = 0
    while index < queue.count, index < webAreaMaxNodes, ProcessInfo.processInfo.systemUptime < deadline {
      let element = queue[index]
      index += 1
      AXUIElementSetMessagingTimeout(element, messagingTimeout)
      if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" {
        return stringValue(attribute(element, "AXURL"))
      }
      queue += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
  }

  static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
  }

  private static func stringValue(_ value: CFTypeRef?) -> String? {
    guard let value else { return nil }
    if let string = value as? String { return string }
    if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! URL).absoluteString }
    return nil
  }
}
