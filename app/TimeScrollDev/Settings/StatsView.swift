import SwiftUI

struct StatsView: View {
  private struct LoadRequest: Equatable {
    var windowIndex: Int
    var refreshCount: Int
  }

  private static let debounce: Duration = .milliseconds(120)
  private static let usageRefreshInterval: Duration = .seconds(6)

  @State private var request = LoadRequest(windowIndex: 0, refreshCount: 0)
  @State private var summary = StatsSummary()

  var body: some View {
    StatsContentView(
      windowIndex: $request.windowIndex,
      summary: summary,
      onRefresh: { request.refreshCount &+= 1 }
    )
    // Reacting to the settled selection replaces any earlier load, so a stale result can neither
    // overwrite a newer one nor be mistaken for one. It ends while the pane is hidden.
    .task(id: request) {
      await load(StatsWindow.all[request.windowIndex])
    }
  }

  private func load(_ window: StatsWindow) async {
    // Dragging the slider passes through several ranges; only query the one it stops on.
    guard (try? await Task.sleep(for: Self.debounce)) != nil else { return }
    let loaded = await Task.detached(priority: .userInitiated) {
      StatsLoader.summary(for: window, now: Date().timeIntervalSince1970)
    }.value
    guard !Task.isCancelled else { return }
    summary = loaded

    // Only usage grows noticeably while the pane is open, and it is by far the cheapest number.
    while (try? await Task.sleep(for: Self.usageRefreshInterval)) != nil {
      let usage = await Task.detached(priority: .utility) {
        StatsLoader.usageSeconds(for: window, now: Date().timeIntervalSince1970)
      }.value
      guard !Task.isCancelled else { return }
      summary.usageSeconds = usage
    }
  }
}
