import Foundation

struct AudioCaptureStartResult: Sendable {
  var microphoneStarted = false
  var systemAudioStarted = false
  var microphoneError: String?
  var systemAudioError: String?

  var startedAny: Bool {
    microphoneStarted || systemAudioStarted
  }
}
