import Foundation

enum CaptureSourceStatus: Equatable {
  case inactive
  case starting
  case running
  case pausedForVault
  case failed(String)

  var isRunning: Bool {
    self == .running
  }

  var errorMessage: String? {
    guard case .failed(let message) = self else { return nil }
    return message
  }
}
