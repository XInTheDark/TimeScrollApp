import CoreGraphics
import Foundation

/// What the capture filters must do about private windows. ScreenCaptureKit cannot exclude single
/// windows alongside excluded apps, so a browser with a private window is excluded as an app and its
/// normal windows are excepted. Its other windows, including popups, stay out until checked.
struct PrivateWindowFilterPlan: Equatable, Sendable {
  var browserPIDs: Set<pid_t> = []
  var exceptedWindowIDs: Set<CGWindowID> = []
  var privateWindowIDs: Set<CGWindowID> = []

  static let empty = PrivateWindowFilterPlan()

  init() {}

  /// `windows` holds every tracked window of the browsers, with its owner and verdict.
  init(windows: [(id: CGWindowID, pid: pid_t, verdict: PrivateWindowVerdict)]) {
    for window in windows where window.verdict == .privateWindow {
      browserPIDs.insert(window.pid)
      privateWindowIDs.insert(window.id)
    }
    for window in windows where window.verdict == .normal && browserPIDs.contains(window.pid) {
      exceptedWindowIDs.insert(window.id)
    }
  }
}
