import Combine

/// Connects the menu bar to the main window. It publishes only when an item's state changes, so
/// scrolling and hovering the timeline never rebuild the menus.
@MainActor
final class TimelineMenuActions: ObservableObject {
  @Published var availability = TimelineMenuAvailability(isLocked: true)
  @Published var isSelecting = false

  /// The views that carry out commands subscribe here, each handling only its own.
  let commands = PassthroughSubject<TimelineMenuCommand, Never>()

  func allows(_ command: TimelineMenuCommand) -> Bool {
    availability.allows(command)
  }

  func perform(_ command: TimelineMenuCommand) {
    guard allows(command) else { return }
    commands.send(command)
  }
}
