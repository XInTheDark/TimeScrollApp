import SwiftUI

/// Which timeline strips are shown. At least one stays visible: turning off the last one beeps.
struct TimelineStripVisibility {
  static let screenKey = "ui.timeline.showScreenStrips"
  static let audioKey = "ui.timeline.showAudioStrips"

  /// Whether the change may be applied: something must remain visible.
  static func allows(visible: Bool, otherVisible: Bool) -> Bool {
    visible || otherVisible
  }

  static func binding(_ value: Binding<Bool>, otherVisible: @escaping () -> Bool) -> Binding<Bool> {
    Binding(
      get: { value.wrappedValue },
      set: { enabled in
        guard allows(visible: enabled, otherVisible: otherVisible()) else {
          NSSound.beep()
          return
        }
        value.wrappedValue = enabled
      })
  }
}
