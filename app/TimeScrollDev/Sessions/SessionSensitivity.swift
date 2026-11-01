import Foundation

/// How readily a change in screen content starts a new session (Preferences ▸ Search).
enum SessionSensitivity: String, CaseIterable, Identifiable {
  case lenient, balanced, strict

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .lenient: return "Lenient"
    case .balanced: return "Balanced"
    case .strict: return "Strict"
    }
  }

  /// Minimum dip in content similarity (TextTiling depth score) that counts as a boundary.
  var depthThreshold: Double {
    switch self {
    case .lenient: return 0.55
    case .balanced: return 0.40
    case .strict: return 0.28
    }
  }

  /// Sessions shorter than this merge into a neighbour (unless an idle gap isolates them).
  var minSessionMs: Int64 {
    switch self {
    case .lenient: return 5 * 60_000
    case .balanced: return 3 * 60_000
    case .strict: return 2 * 60_000
    }
  }

  static let defaultsKey = "settings.sessionSensitivity"

  /// Reads the saved choice straight from `UserDefaults`, so background code never touches `SettingsStore`.
  static func stored(in defaults: UserDefaults = .standard) -> SessionSensitivity {
    defaults.string(forKey: defaultsKey).flatMap(SessionSensitivity.init(rawValue:)) ?? .balanced
  }
}
