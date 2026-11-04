import Foundation

enum TimelapseError: LocalizedError {
  case empty, locked, unreadable(Int64), encoding, invalidRange

  var errorDescription: String? {
    switch self {
    case .empty: return "There are no screen snapshots in this time range."
    case .locked: return "Vault access changed. Unlock the vault and export again."
    case .unreadable(let time):
      return "No readable snapshots were found in this range (starting \(Date(timeIntervalSince1970: Double(time) / 1000).formatted()))."
    case .encoding: return "The video could not be encoded. Try a lower resolution or a different destination."
    case .invalidRange: return "Choose an end time after the start time."
    }
  }
}
