import ApplicationServices
import Foundation

/// An Accessibility element usable as a dictionary key (CF identity, not Swift identity).
struct AXElementRef: Hashable {
    let element: AXUIElement

    static func == (lhs: AXElementRef, rhs: AXElementRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Reads other apps' elements over Accessibility IPC. Before every call it caps the element's
/// messaging timeout at the time left, so an app that hangs costs at most the remaining budget.
struct AXLiveNodeSource: AXNodeSource {
    typealias Element = AXElementRef

    private static let nodeAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXValueAttribute,
    ] as CFArray
    /// The same without the value, for elements known to hold a long document.
    private static let nodeAttributesWithoutValue = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ] as CFArray
    private static let frameAttributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray

    func node(_ element: AXElementRef, includeValue: Bool, deadline: AXDeadline) -> AXNode<AXElementRef>? {
        guard arm(element.element, deadline) else { return nil }
        let attributes = includeValue ? Self.nodeAttributes : Self.nodeAttributesWithoutValue
        var valuesRef: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element.element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef)
        guard result == .success, let values = valuesRef, CFArrayGetCount(values) == CFArrayGetCount(attributes) else {
            // Timed out or gone: give up on this element. Anything else: the app may not batch.
            if result == .cannotComplete || result == .invalidUIElement { return nil }
            return nodeBySingleReads(element, includeValue: includeValue, deadline: deadline)
        }
        func item(_ index: Int) -> AnyObject? {
            Self.unwrap(unsafeBitCast(CFArrayGetValueAtIndex(values, index), to: AnyObject.self))
        }
        return AXNode(role: item(0) as? String ?? "",
                      subrole: item(1) as? String,
                      value: includeValue ? item(7) as? String : nil,
                      title: item(2) as? String,
                      description: item(3) as? String,
                      children: (item(4) as? [AXUIElement])?.map(AXElementRef.init) ?? [],
                      frame: Self.frame(position: item(5), size: item(6)))
    }

    func visibleChildren(_ element: AXElementRef, role: String, deadline: AXDeadline) -> [AXElementRef]? {
        let isTable = role == kAXTableRole as String || role == kAXOutlineRole as String
        let attribute = isTable ? kAXVisibleRowsAttribute : kAXVisibleChildrenAttribute
        return (copy(element.element, attribute, deadline) as? [AXUIElement])?.map(AXElementRef.init)
    }

    func frame(_ element: AXElementRef, deadline: AXDeadline) -> CGRect? {
        guard arm(element.element, deadline) else { return nil }
        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element.element, Self.frameAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
              let values = valuesRef, CFArrayGetCount(values) == 2 else { return nil }
        let position = Self.unwrap(unsafeBitCast(CFArrayGetValueAtIndex(values, 0), to: AnyObject.self))
        let size = Self.unwrap(unsafeBitCast(CFArrayGetValueAtIndex(values, 1), to: AnyObject.self))
        return Self.frame(position: position, size: size)
    }

    func value(_ element: AXElementRef, deadline: AXDeadline) -> String? {
        copy(element.element, kAXValueAttribute, deadline) as? String
    }

    func visibleCharacterRange(_ element: AXElementRef, deadline: AXDeadline) -> NSRange? {
        guard let object = copy(element.element, kAXVisibleCharacterRangeAttribute, deadline),
              CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(object as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func string(_ element: AXElementRef, range: NSRange, deadline: AXDeadline) -> String? {
        guard arm(element.element, deadline) else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element.element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success else { return nil }
        return result as? String
    }

    // MARK: - Helpers

    /// Caps the element's IPC timeout at the time left; false once the hard deadline has passed.
    private func arm(_ element: AXUIElement, _ deadline: AXDeadline) -> Bool {
        guard let remaining = deadline.remainingSeconds() else { return false }
        AXUIElementSetMessagingTimeout(element, max(remaining, 0.001))
        return true
    }

    private func copy(_ element: AXUIElement, _ attribute: String, _ deadline: AXDeadline) -> AnyObject? {
        guard arm(element, deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func nodeBySingleReads(_ element: AXElementRef, includeValue: Bool, deadline: AXDeadline) -> AXNode<AXElementRef>? {
        let ax = element.element
        guard let role = copy(ax, kAXRoleAttribute, deadline) as? String else { return nil }
        return AXNode(role: role,
                      subrole: copy(ax, kAXSubroleAttribute, deadline) as? String,
                      value: includeValue ? copy(ax, kAXValueAttribute, deadline) as? String : nil,
                      title: copy(ax, kAXTitleAttribute, deadline) as? String,
                      description: copy(ax, kAXDescriptionAttribute, deadline) as? String,
                      children: (copy(ax, kAXChildrenAttribute, deadline) as? [AXUIElement])?.map(AXElementRef.init) ?? [],
                      frame: frame(element, deadline: deadline))
    }

    /// A batched read puts an AXValue of type `.axError` where an attribute failed.
    private static func unwrap(_ object: AnyObject) -> AnyObject? {
        if CFGetTypeID(object) == AXValueGetTypeID(), AXValueGetType(object as! AXValue) == .axError { return nil }
        return object
    }

    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
