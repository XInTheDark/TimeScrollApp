import Foundation
import Testing
@testable import TimeScroll

/// Plaintext segments left by older versions are encrypted or removed once the vault is on,
/// never ones still being written or ones a row references directly.
struct VaultSegmentRemnantPlannerTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  private let dir = URL(fileURLWithPath: "/root/Videos", isDirectory: true)

  private func file(_ name: String, ageMinutes: Double) -> OrphanSegmentPlanner.SegmentFile {
    .init(url: dir.appendingPathComponent(name), modifiedAt: now.addingTimeInterval(-ageMinutes * 60))
  }

  @Test func sealedDuplicateIsRemovedAndUnsealedIsSealed() {
    let files = [
      file("seg-2026-01-01-10-00-00-d1.mov", ageMinutes: 60),
      file("seg-2026-01-01-10-00-00-d1.tse", ageMinutes: 60),
      file("seg-2026-01-01-10-01-00-d1.mov", ageMinutes: 60)
    ]
    let actions = VaultSegmentRemnantPlanner.actions(in: files, referencedPaths: [], now: now)
    #expect(actions == [
      .removeSealedDuplicate(mov: dir.appendingPathComponent("seg-2026-01-01-10-00-00-d1.mov"),
                             tse: dir.appendingPathComponent("seg-2026-01-01-10-00-00-d1.tse")),
      .seal(mov: dir.appendingPathComponent("seg-2026-01-01-10-01-00-d1.mov"),
            tse: dir.appendingPathComponent("seg-2026-01-01-10-01-00-d1.tse"))
    ])
  }

  @Test func recentAndReferencedMoviesAreLeftAlone() {
    let referenced = file("seg-2026-01-01-10-02-00-d1.mov", ageMinutes: 60)
    let files = [file("seg-2026-01-01-10-03-00-d1.mov", ageMinutes: 1), referenced, file("notes.txt", ageMinutes: 60)]
    #expect(VaultSegmentRemnantPlanner.actions(in: files, referencedPaths: [referenced.url.path], now: now).isEmpty)
  }

  @Test func emptyFolderPlansNothing() {
    #expect(VaultSegmentRemnantPlanner.actions(in: [], referencedPaths: [], now: now).isEmpty)
  }
}
