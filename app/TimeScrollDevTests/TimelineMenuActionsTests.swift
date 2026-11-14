import Combine
import Testing
@testable import TimeScroll

@MainActor
struct TimelineMenuActionsTests {
  private let stageCommands: [TimelineMenuCommand] = [.findInSnapshot, .revealInFinder, .saveSnapshot]

  // MARK: - Availability

  @Test func screenSnapshotAllowsEverything() {
    let availability = TimelineMenuAvailability(selectedKind: .screen)
    for command in stageCommands + [.toggleSelection] {
      #expect(availability.allows(command))
    }
  }

  @Test func audioSelectionOnlyRevealsAndSelects() {
    let availability = TimelineMenuAvailability(selectedKind: .audio)
    #expect(!availability.allows(.findInSnapshot))
    #expect(!availability.allows(.saveSnapshot))
    #expect(availability.allows(.revealInFinder))
    #expect(availability.allows(.toggleSelection))
  }

  @Test func emptyTimelineOnlySelects() {
    let availability = TimelineMenuAvailability(selectedKind: nil)
    for command in stageCommands {
      #expect(!availability.allows(command))
    }
    #expect(availability.allows(.toggleSelection))
  }

  @Test func searchResultsHideTheStageButKeepSelect() {
    for kind in [CaptureKind.screen, .audio] {
      let availability = TimelineMenuAvailability(selectedKind: kind, isShowingResults: true)
      for command in stageCommands {
        #expect(!availability.allows(command))
      }
      #expect(availability.allows(.toggleSelection))
    }
  }

  @Test func lockedVaultAllowsNothing() {
    for kind in [CaptureKind.screen, .audio, nil] {
      for showingResults in [false, true] {
        let availability = TimelineMenuAvailability(selectedKind: kind, isShowingResults: showingResults, isLocked: true)
        for command in stageCommands + [.toggleSelection] {
          #expect(!availability.allows(command))
        }
      }
    }
  }

  // MARK: - Dispatch

  private func recording(_ actions: TimelineMenuActions) -> (box: Recorder, subscription: AnyCancellable) {
    let box = Recorder()
    let subscription = actions.commands.sink { box.commands.append($0) }
    return (box, subscription)
  }

  private final class Recorder {
    var commands: [TimelineMenuCommand] = []
  }

  @Test func startsDisabledUntilTheWindowReportsItsState() {
    let actions = TimelineMenuActions()
    for command in stageCommands + [.toggleSelection] {
      #expect(!actions.allows(command))
    }
    #expect(!actions.isSelecting)
  }

  @Test func allowedCommandsReachSubscribersOncePerRequest() {
    let actions = TimelineMenuActions()
    actions.availability = TimelineMenuAvailability(selectedKind: .screen)
    let (recorder, subscription) = recording(actions)
    actions.perform(.saveSnapshot)
    actions.perform(.toggleSelection)
    #expect(recorder.commands == [.saveSnapshot, .toggleSelection])
    subscription.cancel()
  }

  @Test func disallowedCommandsAreDropped() {
    let actions = TimelineMenuActions()
    actions.availability = TimelineMenuAvailability(selectedKind: .audio)
    let (recorder, subscription) = recording(actions)
    actions.perform(.saveSnapshot)
    actions.perform(.findInSnapshot)
    #expect(recorder.commands.isEmpty)
    actions.perform(.revealInFinder)
    #expect(recorder.commands == [.revealInFinder])
    subscription.cancel()
  }

  @Test func lockingAfterAnEnabledStateDropsCommands() {
    let actions = TimelineMenuActions()
    actions.availability = TimelineMenuAvailability(selectedKind: .screen)
    actions.availability = TimelineMenuAvailability(selectedKind: .screen, isLocked: true)
    let (recorder, subscription) = recording(actions)
    actions.perform(.revealInFinder)
    actions.perform(.toggleSelection)
    #expect(recorder.commands.isEmpty)
    subscription.cancel()
  }

  @Test func performWithNoSubscribersIsHarmless() {
    let actions = TimelineMenuActions()
    actions.availability = TimelineMenuAvailability(selectedKind: .screen)
    actions.perform(.saveSnapshot)
  }

  @Test func timeWarpToMomentNeedsASelectedSnapshot() {
    #expect(TimelineMenuAvailability(selectedKind: .screen).allows(.timeWarpToMoment))
    #expect(TimelineMenuAvailability(selectedKind: .audio).allows(.timeWarpToMoment))
    #expect(!TimelineMenuAvailability(selectedKind: nil).allows(.timeWarpToMoment))
    #expect(!TimelineMenuAvailability(selectedKind: .screen, isShowingResults: true).allows(.timeWarpToMoment))
    #expect(!TimelineMenuAvailability(selectedKind: .screen, isLocked: true).allows(.timeWarpToMoment))
  }
}
