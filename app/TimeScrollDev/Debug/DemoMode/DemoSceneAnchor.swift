#if DEBUG
import SwiftUI

/// Gives the demo director the timeline view's state once the view is on screen.
struct DemoSceneAnchor: View {
  let timeline: TimelineModel
  let selection: TimelineRangeSelection
  let search: (String) -> Void

  var body: some View {
    Color.clear.task {
      await DemoDirector.shared.timelineAppeared(timeline: timeline, selection: selection, search: search)
    }
  }
}
#endif
