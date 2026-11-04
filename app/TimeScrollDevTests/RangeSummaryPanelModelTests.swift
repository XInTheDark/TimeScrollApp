import Foundation
import Testing
@testable import TimeScroll

/// Scripted answers, with generation held open until a test releases it.
private final class FakeSummaryBackend: @unchecked Sendable {
  private let lock = NSLock()
  var modelNames: [String]? = ["lfm3"]
  var storedText: [Int64: StoredRangeSummary] = [:]
  var result = RangeSummaryProvider.Result.generated(text: "Written.", stored: true)
  var hold = false
  var saved: String?
  private(set) var generateCalls: [(TimelineRange, String)] = []
  private(set) var cancelCount = 0
  private var waiting: [CheckedContinuation<RangeSummaryProvider.Result, Never>] = []

  var services: RangeSummaryServices {
    RangeSummaryServices(
      report: { range in AppTimeReport(range: .init(fromMs: range.fromMs, toMs: range.toMs, precision: .exact), rows: [], topK: 8) },
      stored: { [self] range, _ in
        storedText[range.fromMs].map { .stored($0, outdated: false) } ?? RangeSummaryProvider.StoredState.none
      },
      models: { [self] in modelNames },
      generate: { [self] range, model in
        await withCheckedContinuation { continuation in
          lock.lock()
          generateCalls.append((range, model))
          if hold {
            waiting.append(continuation)
            lock.unlock()
          } else {
            let answer = result
            lock.unlock()
            continuation.resume(returning: answer)
          }
        }
      },
      cancel: { [self] in
        lock.lock()
        cancelCount += 1
        lock.unlock()
        release(.cancelled)
      },
      savedModel: { [self] in saved },
      saveModel: { [self] in saved = $0 })
  }

  func release(_ answer: RangeSummaryProvider.Result) {
    lock.lock()
    let continuations = waiting
    waiting = []
    lock.unlock()
    continuations.forEach { $0.resume(returning: answer) }
  }

  var isWaiting: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !waiting.isEmpty
  }
}

@MainActor
final class RangeSummaryPanelModelTests {
  private let backend = FakeSummaryBackend()
  private let range = TimelineRange(fromMs: 1_000, toMs: 2_000)!
  private let otherRange = TimelineRange(fromMs: 5_000, toMs: 6_000)!

  private func makeModel() -> RangeSummaryPanelModel { RangeSummaryPanelModel(services: backend.services) }

  private func waitUntilGenerating() async {
    for _ in 0..<500 where !backend.isWaiting { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
  }

  @Test func openingWithoutARequestNeverStartsTheModel() async {
    let model = makeModel()
    model.show(range, generate: false)
    await model.settle()
    #expect(backend.generateCalls.isEmpty)
    #expect(model.summary == .idle)
    guard case .loaded = model.stats else {
      Issue.record("Stats didn't load")
      return
    }
  }

  @Test func askingGeneratesWithTheOnlyInstalledModel() async {
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(backend.generateCalls.map(\.1) == ["lfm3"])
    #expect(model.selectedModel == "lfm3")
    guard case .text("Written.", savedModel: "lfm3", createdAtMs: _, isOutdated: false) = model.summary else {
      Issue.record("Got \(model.summary)")
      return
    }
  }

  @Test func aStoredSummaryIsShownWithoutRunningTheModel() async {
    backend.storedText[range.fromMs] = StoredRangeSummary(startMs: 1_000, endMs: 2_000, model: "old", promptVersion: SummaryPrompt.version, text: "Stored.", createdAtMs: 7)
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(backend.generateCalls.isEmpty)
    #expect(model.summary == .text("Stored.", savedModel: "old", createdAtMs: 7, isOutdated: false))
  }

  @Test func aSummaryFromAnOlderPromptIsMarkedOutdatedAndStillShown() async {
    backend.storedText[range.fromMs] = StoredRangeSummary(startMs: 1_000, endMs: 2_000, model: "lfm3", promptVersion: SummaryPrompt.version - 1, text: "Stored.", createdAtMs: 7)
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(backend.generateCalls.isEmpty)
    #expect(model.summary == .text("Stored.", savedModel: "lfm3", createdAtMs: 7, isOutdated: true))
  }

  @Test func aSummaryFromAnotherModelIsNotOutdated() async {
    backend.storedText[range.fromMs] = StoredRangeSummary(startMs: 1_000, endMs: 2_000, model: "other", promptVersion: SummaryPrompt.version, text: "Stored.", createdAtMs: 7)
    let model = makeModel()
    model.show(range, generate: false)
    await model.settle()
    #expect(model.summary == .text("Stored.", savedModel: "other", createdAtMs: 7, isOutdated: false))
  }

  @Test func regenerateReplacesAStoredSummary() async {
    backend.storedText[range.fromMs] = StoredRangeSummary(startMs: 1_000, endMs: 2_000, model: "lfm3", promptVersion: 1, text: "Stored.", createdAtMs: 7)
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    model.regenerate()
    await model.settle()
    #expect(backend.generateCalls.count == 1)
    guard case .text("Written.", _, _, _) = model.summary else {
      Issue.record("Got \(model.summary)")
      return
    }
  }

  @Test func anUnsavedSummaryHasNoSavedModel() async {
    backend.result = .generated(text: "Custom.", stored: false)
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(model.summary == .text("Custom.", savedModel: nil, createdAtMs: nil, isOutdated: false))
  }

  // MARK: - Models

  @Test func severalModelsWaitForAChoice() async {
    backend.modelNames = ["a", "b"]
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(backend.generateCalls.isEmpty)
    #expect(model.summary == .problem(.chooseModel))
    model.select(model: "b")
    #expect(backend.saved == "b")
    model.regenerate()
    await model.settle()
    #expect(backend.generateCalls.map(\.1) == ["b"])
  }

  @Test func theSavedModelIsReused() async {
    backend.modelNames = ["a", "b"]
    backend.saved = "b"
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(backend.generateCalls.map(\.1) == ["b"])
  }

  @Test func aSavedModelMatchesItsLatestTag() async {
    backend.modelNames = ["lfm3:latest", "other"]
    backend.saved = "lfm3"
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(backend.generateCalls.map(\.1) == ["lfm3"])
  }

  @Test func aRemovedSavedModelIsNotUsed() async {
    backend.modelNames = ["a", "b"]
    backend.saved = "gone"
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(model.selectedModel == nil)
    #expect(model.summary == .problem(.chooseModel))
  }

  @Test func ollamaDownIsReportedAndCanBeRetried() async {
    backend.modelNames = nil
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(model.summary == .problem(.ollamaUnavailable))
    backend.modelNames = ["lfm3"]
    model.retry()
    await model.settle()
    #expect(backend.generateCalls.count == 1)
  }

  @Test func noTextModelsIsReported() async {
    backend.modelNames = []
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    #expect(model.summary == .problem(.noModels))
  }

  @Test func everyFailureMapsToAProblem() async {
    let cases: [(RangeSummaryProvider.Result, RangeSummaryPanelModel.Problem)] = [
      (.noActivity, .noActivity), (.ollamaUnavailable, .ollamaUnavailable), (.modelNotInstalled, .modelNotInstalled),
      (.modelUnsuitable, .modelUnsuitable), (.cloudModelRefused, .cloudModelRefused), (.failed, .failed),
      (.discarded, .discarded), (.vaultLocked, .vaultLocked),
    ]
    for (result, problem) in cases {
      backend.result = result
      let model = makeModel()
      model.show(range, generate: true)
      await model.settle()
      #expect(model.summary == .problem(problem))
    }
  }

  // MARK: - Races

  @Test func changingTheRangeStopsTheRequestAndIgnoresItsResult() async {
    backend.hold = true
    let model = makeModel()
    model.show(range, generate: true)
    let settled = Task { await model.settle() }
    await waitUntilGenerating()
    #expect(model.summary == .generating)
    model.show(otherRange, generate: false)
    await settled.value
    await model.settle()
    #expect(backend.cancelCount == 1)
    #expect(model.summary == .idle)
  }

  @Test func aLateResultForAnOldRangeIsDropped() async {
    backend.hold = true
    let model = makeModel()
    model.show(range, generate: true)
    await waitUntilGenerating()
    model.show(otherRange, generate: false)
    backend.release(.generated(text: "Old range.", stored: false))
    await model.settle()
    #expect(model.summary == .idle)
  }

  @Test func cancellingReturnsToIdle() async {
    backend.hold = true
    let model = makeModel()
    model.show(range, generate: true)
    await waitUntilGenerating()
    model.cancelGenerating()
    await model.settle()
    #expect(backend.cancelCount == 1)
    #expect(model.summary == .idle)
  }

  @Test func closingStopsTheRequestAndForgetsTheText() async {
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    model.close()
    #expect(model.summary == .idle)
    #expect(model.stats == .loading)

    backend.hold = true
    model.show(range, generate: true)
    await waitUntilGenerating()
    model.close()
    await model.settle()
    #expect(backend.cancelCount == 1)
    #expect(model.summary == .idle)
  }

  @Test func reopeningTheSameRangeAfterClosingLoadsAgain() async {
    let model = makeModel()
    model.show(range, generate: false)
    await model.settle()
    model.close()
    model.show(range, generate: false)
    await model.settle()
    guard case .loaded = model.stats else {
      Issue.record("Stats didn't load")
      return
    }
  }

  @Test func showingTheSameRangeAgainDoesNothing() async {
    let model = makeModel()
    model.show(range, generate: true)
    await model.settle()
    model.show(range, generate: false)
    await model.settle()
    #expect(backend.generateCalls.count == 1)
    guard case .text = model.summary else {
      Issue.record("Lost the text")
      return
    }
  }
}

@MainActor
struct RangeActionsModelTests {
  private let filter = SnapshotRangeFilter(fromMs: 0, toMs: 100)

  @Test func onlyTheNewestCountIsShown() async {
    let seen = LockedBox<[Int64]>([])
    let model = RangeActionsModel(countDelay: .milliseconds(20), countRows: { filter in
      seen.update { $0.append(filter.toMs) }
      return .init(screen: Int(filter.toMs), audio: 0)
    })
    model.refreshCount(for: SnapshotRangeFilter(fromMs: 0, toMs: 1))
    model.refreshCount(for: SnapshotRangeFilter(fromMs: 0, toMs: 2))
    model.refreshCount(for: SnapshotRangeFilter(fromMs: 0, toMs: 3))
    await model.settleCount()
    #expect(model.count == .init(screen: 3, audio: 0))
    #expect(seen.value == [3])
  }

  @Test func clearingTheRangeClearsTheCount() async {
    let model = RangeActionsModel(countDelay: .zero, countRows: { _ in .init(screen: 1, audio: 0) })
    model.refreshCount(for: filter)
    await model.settleCount()
    #expect(model.count != nil)
    model.refreshCount(for: nil)
    #expect(model.count == nil)
  }

  @Test func aFailedDeleteIsReported() async {
    let model = RangeActionsModel(deleteRows: { _, _ in false })
    #expect(await model.delete(filter) == false)
    #expect(model.deleteFailed)
    #expect(!model.isDeleting)
  }

  @Test func aSuccessfulDeleteClearsAnEarlierFailure() async {
    let succeed = LockedBox(false)
    let model = RangeActionsModel(deleteRows: { _, progress in
      progress(5)
      return succeed.value
    })
    _ = await model.delete(filter)
    #expect(model.deleteFailed)
    succeed.update { $0 = true }
    #expect(await model.delete(filter))
    #expect(!model.deleteFailed)
  }
}

private final class LockedBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: T
  init(_ value: T) { stored = value }
  var value: T {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func update(_ body: (inout T) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&stored)
  }
}
