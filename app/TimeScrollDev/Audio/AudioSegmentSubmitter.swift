import Foundation

final class AudioSegmentSubmitter: @unchecked Sendable {
  private let group = DispatchGroup()

  func submit(_ segment: RecordedAudioSegment, modelID: String) {
    group.enter()
    Task {
      await AudioSegmentProcessor.shared.submit(segment, modelID: modelID)
      group.leave()
    }
  }

  func drainSubmissions() async {
    await withCheckedContinuation { continuation in
      group.notify(queue: .global(qos: .utility)) {
        continuation.resume()
      }
    }
  }
}
