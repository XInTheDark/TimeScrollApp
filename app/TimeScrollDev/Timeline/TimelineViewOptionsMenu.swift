import SwiftUI

/// The timeline toolbar's View menu: live follow, the session band, and how the axis behaves.
/// A live indicator stays visible next to it while following the newest captures.
struct TimelineViewOptionsMenu: View {
  @Binding var followLatest: Bool
  @AppStorage("ui.timeline.showSessions") private var showSessions: Bool = true
  @AppStorage("ui.timeline.compressed") private var compressedTimeline: Bool = true
  @AppStorage("ui.timeline.invertScrollDirection") private var invertScrollDirection: Bool = false

  var body: some View {
    HStack(spacing: 8) {
      if followLatest {
        Image(systemName: "dot.radiowaves.left.and.right")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .help("Following newest snapshots")
          .accessibilityLabel("Live follow on")
      }

      Menu {
        Toggle(isOn: $followLatest) {
          Label("Live", systemImage: "dot.radiowaves.left.and.right")
        }
        Toggle(isOn: $showSessions) {
          Label("Show Sessions", systemImage: "rectangle.split.3x1")
        }
        Divider()
        Toggle("Compressed Timeline", isOn: $compressedTimeline)
        Toggle("Invert Scroll Direction", isOn: $invertScrollDirection)
      } label: {
        Label("View", systemImage: "eye")
      }
      .menuStyle(.borderedButton)
      .fixedSize()
      .help("View options")
    }
  }
}
