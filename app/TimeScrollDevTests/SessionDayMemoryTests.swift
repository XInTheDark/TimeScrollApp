import Foundation
import Testing
@testable import TimeScroll

struct SessionDayMemoryTests {
  private func entry(keyword: String = "private", settled: Bool = true) -> SessionDayMemory.Entry {
    let session = ActivitySession(id: 1, startMs: 1, endMs: 2, snapshotCount: 1, apps: [], keywords: [keyword])
    return SessionDayMemory.Entry(params: "v1|balanced", sessions: [session], checkedAtMs: 0, settled: settled)
  }

  @Test func anEmptyMemoryHasNothing() {
    var memory = SessionDayMemory()
    memory.sync(invalidations: 0)
    #expect(memory[100] == nil)
  }

  @Test func theSameCountKeepsEntries() {
    var memory = SessionDayMemory()
    memory.sync(invalidations: 3)
    memory[100] = entry()
    memory.sync(invalidations: 3)
    #expect(memory[100]?.sessions.first?.keywords == ["private"])
  }

  // A settled day is otherwise trusted forever, so this is what keeps deleted keywords out.
  @Test func aChangedCountForgetsEverySettledDay() {
    var memory = SessionDayMemory()
    memory.sync(invalidations: 3)
    memory[100] = entry()
    memory[200] = entry()
    memory.sync(invalidations: 4)
    #expect(memory[100] == nil)
    #expect(memory[200] == nil)
  }

  // Computing started before a delete and remembered after it: the next request still drops it.
  @Test func anEntryRememberedAfterADeleteIsForgottenByTheNextRequest() {
    var memory = SessionDayMemory()
    memory.sync(invalidations: 3)
    memory[100] = entry()
    memory.sync(invalidations: 4)
    #expect(memory[100] == nil)
    memory[100] = entry(keyword: "fresh")
    memory.sync(invalidations: 4)
    #expect(memory[100]?.sessions.first?.keywords == ["fresh"])
  }

  @Test func removeAllForgetsEntries() {
    var memory = SessionDayMemory()
    memory.sync(invalidations: 3)
    memory[100] = entry()
    memory.removeAll()
    #expect(memory[100] == nil)
  }
}
