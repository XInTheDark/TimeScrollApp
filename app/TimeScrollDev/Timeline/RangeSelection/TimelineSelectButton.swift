import SwiftUI

/// Turns range selection on and off from the timeline toolbar.
struct TimelineSelectButton: View {
  @ObservedObject var selection: TimelineRangeSelection

  var body: some View {
    Group {
      if selection.isActive {
        button.buttonStyle(.borderedProminent)
      } else {
        button.buttonStyle(.bordered)
      }
    }
    .help("Select a time range")
  }

  private var button: some View {
    Button { selection.toggle() } label: {
      Label("Select", systemImage: "selection.pin.in.out")
    }
  }
}
