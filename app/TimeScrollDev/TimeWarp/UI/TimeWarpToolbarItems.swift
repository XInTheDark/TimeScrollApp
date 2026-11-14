import AppKit
import SwiftUI

/// Time Warp in the snapshot toolbar: a Time Warp to this moment and, when Time Warp knows the
/// page or file that was in front, a button that opens it. Hidden while Time Warp is off.
struct TimeWarpToolbarItems: View {
  let snapshot: SnapshotMeta
  @State private var item: TimeWarpPlanItem?
  @AppStorage(TimeWarpSettings.enabledKey) private var isEnabled = true

  var body: some View {
    Group {
      if isEnabled && snapshot.captureKind == .screen {
        Button {
          TimeWarpWindowController.shared.present(momentMs: snapshot.startedAtMs)
        } label: {
          Image(systemName: "clock.arrow.circlepath")
        }
        .help("Time Warp to this moment")
        .accessibilityLabel("Time Warp to this moment")
        if let item {
          Button {
            Task { if await TimeWarpLauncher.open([item], inNewWindow: false).opened == 0 { NSSound.beep() } }
          } label: {
            Label(Self.openTitle(item), systemImage: "arrow.up.forward.app")
              .labelStyle(.titleAndIcon)
              .font(.system(size: 13, weight: .medium))
          }
          .help(Self.help(item))
        }
      }
    }
    .task(id: snapshot.id) { item = await Self.load(snapshot) }
  }

  static func openTitle(_ item: TimeWarpPlanItem) -> String {
    switch item.kind {
    case .page: return "Open Page"
    case .folder: return "Open Folder"
    default: return "Open File"
    }
  }

  private static func help(_ item: TimeWarpPlanItem) -> String {
    let text = TimeWarpItemText(item: item)
    return text.subtitle.map { "\(text.title)\n\($0)" } ?? item.value
  }

  private static func load(_ snapshot: SnapshotMeta) async -> TimeWarpPlanItem? {
    guard snapshot.captureKind == .screen, let bundleId = snapshot.appBundleId else { return nil }
    let timeMs = snapshot.startedAtMs
    return await Task.detached(priority: .userInitiated) { () -> TimeWarpPlanItem? in
      guard let record = try? DB.shared.timeWarpFrontItem(atMs: timeMs, appBundleId: bundleId),
            [.page, .document, .folder].contains(record.kind) else { return nil }
      return TimeWarpPlanItem(kind: record.kind, value: record.value, title: record.title, appBundleId: record.appBundleId,
                              frontMs: 0, visits: 1, lastSeenMs: record.endMs, wasOpenAtEnd: false)
    }.value
  }
}
