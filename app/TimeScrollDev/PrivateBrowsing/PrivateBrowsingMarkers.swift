import Foundation

/// The text browsers add to the Accessibility data of a private window. Chrome, Brave and Firefox
/// tables live in the generated file; only hand-collected values belong here.
enum PrivateBrowsingMarkers {
  struct TitleAffix: Equatable, Sendable {
    let prefix: String
    let suffix: String

    func matches(_ title: String) -> Bool {
      title.hasPrefix(prefix) && title.hasSuffix(suffix)
    }
  }

  /// Safari's strings are not in readable files. English was measured on Safari 27.2 and Swedish
  /// comes from a reported Safari 26 probe.
  static let safariTitleAffixes: [TitleAffix] = [
    TitleAffix(prefix: "", suffix: ", Private Browsing"),
    TitleAffix(prefix: "", suffix: ", privat surfning"),
  ]

  static let safariAddressFieldDescriptions = [
    "in a private window",
    "i ett privat fönster",
  ]

  /// Directional marks that some translations carry around otherwise identical text.
  static func normalized(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { !isDirectionalMark($0) }))
  }

  private static func isDirectionalMark(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
    default: return false
    }
  }
}
