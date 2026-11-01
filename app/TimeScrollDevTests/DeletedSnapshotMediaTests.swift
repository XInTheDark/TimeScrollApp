import Foundation
import Testing
@testable import TimeScroll

struct DeletedSnapshotMediaTests {
  private let nowMs: Int64 = 1_800_000_000_000
  private var oldMs: Int64 { nowMs - DeletedSnapshotMedia.openSegmentGraceMs }
  private let segment = "/data/Videos/seg-2026-10-30-21-00-00-d1.tse"
  private let poster = "/data/Posters/p-1.jpg"

  private func remove(path: String?, thumb: String?, startedAtMs: Int64, referenced: Set<String> = []) -> [String] {
    DeletedSnapshotMedia.filesToRemove(path: path, thumbPath: thumb, startedAtMs: startedAtMs, nowMs: nowMs) { file in
      DeletedSnapshotMedia.equivalentPaths(of: file).contains { referenced.contains($0) }
    }
  }

  @Test func sharedSegmentIsKeptButPosterGoes() {
    // Other snapshots of the same minute still use the segment.
    #expect(remove(path: segment, thumb: poster, startedAtMs: oldMs, referenced: [segment]) == [poster])
  }

  @Test func lastSnapshotOfFinishedMinuteTakesSegment() {
    #expect(remove(path: segment, thumb: poster, startedAtMs: oldMs) == [segment, poster])
  }

  @Test func segmentStillBeingWrittenIsLeftForSweeper() {
    #expect(remove(path: segment, thumb: poster, startedAtMs: nowMs - 30_000) == [poster])
    #expect(remove(path: segment, thumb: nil, startedAtMs: oldMs + 1).isEmpty)
  }

  @Test func referenceThroughOtherExtensionKeepsSegment() {
    // A remaining row points at the live .mov of the same segment.
    let live = "/data/Videos/seg-2026-10-30-21-00-00-d1.mov"
    #expect(remove(path: segment, thumb: nil, startedAtMs: oldMs, referenced: [live]).isEmpty)
  }

  @Test func otherDisplaySegmentDoesNotCount() {
    let otherDisplay = "/data/Videos/seg-2026-10-30-21-00-00-d2.tse"
    #expect(remove(path: segment, thumb: nil, startedAtMs: oldMs, referenced: [otherDisplay]) == [segment])
  }

  @Test func stillImageIsRemovedImmediately() {
    let heic = "/data/Snapshots/2026-10-30/snap-1.heic"
    #expect(remove(path: heic, thumb: nil, startedAtMs: nowMs) == [heic])
  }

  @Test func sharedStillImageIsKept() {
    let heic = "/data/Snapshots/2026-10-30/snap-1.heic"
    #expect(remove(path: heic, thumb: nil, startedAtMs: oldMs, referenced: [heic]).isEmpty)
  }

  @Test func posterUsedElsewhereIsKept() {
    #expect(remove(path: segment, thumb: poster, startedAtMs: oldMs, referenced: [poster]) == [segment])
  }

  @Test func missingOrEmptyPathsRemoveNothing() {
    #expect(remove(path: nil, thumb: nil, startedAtMs: oldMs).isEmpty)
    #expect(remove(path: "", thumb: "", startedAtMs: oldMs).isEmpty)
  }

  @Test func thumbSameAsPathIsListedOnce() {
    let heic = "/data/Snapshots/2026-10-30/snap-1.heic"
    #expect(remove(path: heic, thumb: heic, startedAtMs: oldMs) == [heic])
  }

  @Test func unknownReferenceKeepsFiles() {
    // The DB hook treats a failed query as referenced.
    let files = DeletedSnapshotMedia.filesToRemove(path: segment, thumbPath: poster, startedAtMs: oldMs, nowMs: nowMs) { _ in true }
    #expect(files.isEmpty)
  }

  @Test func equivalentPathsCoverBothSegmentExtensions() {
    #expect(DeletedSnapshotMedia.equivalentPaths(of: segment) == [
      segment,
      "/data/Videos/seg-2026-10-30-21-00-00-d1.mov",
    ])
    #expect(DeletedSnapshotMedia.equivalentPaths(of: poster) == [poster])
  }
}
