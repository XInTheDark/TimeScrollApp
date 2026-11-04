import Foundation
import Testing
@testable import TimeScroll

struct TimelapseOutputFileTests {
  @Test func completedOutputCreatesThenAtomicallyReplacesDestination() throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("timelapse-output-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: destination) }
    for contents in ["first movie", "replacement movie"] {
      let output = TimelapseOutputFile(destination: destination)
      defer { output.discard() }
      try Data(contents.utf8).write(to: output.temporary)
      try output.publish(check: {})
      #expect(try String(contentsOf: destination, encoding: .utf8) == contents)
      #expect(!FileManager.default.fileExists(atPath: output.temporary.path))
    }
  }

  @Test func cancelledAndRevokedAccessNeverReplaceAnExistingFile() throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("timelapse-protected-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: destination) }
    try Data("original movie".utf8).write(to: destination)
    for revoked in [false, true] {
      let output = TimelapseOutputFile(destination: destination)
      try Data("partial movie".utf8).write(to: output.temporary)
      do {
        try output.publish(check: {
          if revoked { throw TimelapseError.locked }
          throw CancellationError()
        })
        Issue.record("Publication should require current access and an active task")
      } catch {
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original movie")
      }
      output.discard()
      #expect(!FileManager.default.fileExists(atPath: output.temporary.path))
    }
  }
}
