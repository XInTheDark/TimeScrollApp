import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut through Carbon's hot key API, which needs no permission and costs nothing
/// until it is pressed.
@MainActor
final class TimeWarpHotKey {
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let action: () -> Void

  /// ⌃⌥⌘W.
  static let keyCode = UInt32(kVK_ANSI_W)
  static let modifiers = UInt32(controlKey | optionKey | cmdKey)
  private static let signature: OSType = 0x5457_5250 // "TWRP"

  init(action: @escaping () -> Void) {
    self.action = action
  }

  var isRegistered: Bool { hotKeyRef != nil }

  /// False when another app already owns the shortcut.
  @discardableResult
  func register() -> Bool {
    guard hotKeyRef == nil else { return true }
    if handlerRef == nil {
      var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let context = Unmanaged.passUnretained(self).toOpaque()
      InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard id.signature == TimeWarpHotKey.signature else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<TimeWarpHotKey>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { hotKey.action() }
        return noErr
      }, 1, &type, context, &handlerRef)
    }
    let id = EventHotKeyID(signature: Self.signature, id: 1)
    let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    if status != noErr { hotKeyRef = nil }
    return status == noErr
  }

  func unregister() {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    hotKeyRef = nil
  }
}
