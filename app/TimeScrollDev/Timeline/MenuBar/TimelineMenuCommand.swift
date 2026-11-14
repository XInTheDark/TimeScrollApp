/// What a timeline item in the menu bar can ask the main window to do.
enum TimelineMenuCommand: Equatable {
  case findInSnapshot
  case revealInFinder
  case saveSnapshot
  case timeWarpToMoment
  case toggleSelection
}
