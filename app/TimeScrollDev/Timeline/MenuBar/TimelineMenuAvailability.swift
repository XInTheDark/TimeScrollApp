/// Which timeline menu items work for what the main window is showing right now.
struct TimelineMenuAvailability: Equatable {
  private enum Stage: Equatable {
    case none
    case screen
    case audio
  }

  private let stage: Stage
  private let canSelect: Bool

  init(selectedKind: CaptureKind? = nil, isShowingResults: Bool = false, isLocked: Bool = false) {
    canSelect = !isLocked
    if isLocked || isShowingResults {
      stage = .none
    } else {
      switch selectedKind {
      case .screen: stage = .screen
      case .audio: stage = .audio
      case nil: stage = .none
      }
    }
  }

  func allows(_ command: TimelineMenuCommand) -> Bool {
    switch command {
    case .showSnapshotActions, .saveSnapshot:
      return stage == .screen
    case .revealInFinder:
      return stage != .none
    case .toggleSelection:
      return canSelect
    }
  }
}
