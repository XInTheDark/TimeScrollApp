import SwiftUI

struct TimelineRefreshObserver: NSViewRepresentable {
  let scheduler: TimelineLiveRefreshScheduler
  let refresh: () -> Void
  let isReady: () -> Bool
  let isEnabled: () -> Bool

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.scheduler = scheduler
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {
    scheduler.refresh = refresh
    scheduler.isReady = isReady
    scheduler.isEnabled = isEnabled
    scheduler.attach(to: view.window)
  }

  static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
    view.scheduler?.attach(to: nil)
    view.scheduler?.refresh = {}
    view.scheduler?.isReady = { true }
    view.scheduler?.isEnabled = { true }
  }

  final class ObserverView: NSView {
    weak var scheduler: TimelineLiveRefreshScheduler?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduler?.attach(to: window)
    }
  }
}
