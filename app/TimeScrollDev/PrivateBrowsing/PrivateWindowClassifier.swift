import Foundation

/// What Accessibility reports about one browser window.
struct PrivateWindowEvidence: Equatable, Sendable {
  var title: String?
  var subrole: String?
  var hasCloseButton: Bool
  /// Read only for browsers with an address field rule, and only when the title has no marker.
  var addressFieldDescription: String?
}

enum PrivateWindowVerdict: Equatable, Sendable {
  case privateWindow
  case normal
  /// A popup, bubble or other secondary window. It has no marker of its own, so its owner is unknown.
  case auxiliary
  /// Could not be decided yet, for example a window whose title has not been set.
  case undetermined
}

/// Turns evidence into a verdict. A missing marker means "no marker found": an untranslated language
/// or a changed browser string also looks normal, so detection is best effort.
enum PrivateWindowClassifier {
  static let standardWindowSubrole = "AXStandardWindow"

  static func hasMarker(_ evidence: PrivateWindowEvidence, profile: PrivateBrowsingProfile) -> Bool {
    if let title = evidence.title.map(PrivateBrowsingMarkers.normalized), titleHasMarker(title, profile: profile) {
      return true
    }
    if let rule = profile.addressField,
       let description = evidence.addressFieldDescription.map(PrivateBrowsingMarkers.normalized) {
      return rule.descriptions.contains { description.contains($0) }
    }
    return false
  }

  static func titleHasMarker(_ title: String, profile: PrivateBrowsingProfile) -> Bool {
    profile.titleAffixes.contains { $0.matches(title) } || profile.titleSubstrings.contains { title.contains($0) }
  }

  static func verdict(for evidence: PrivateWindowEvidence, profile: PrivateBrowsingProfile) -> PrivateWindowVerdict {
    if hasMarker(evidence, profile: profile) { return .privateWindow }
    // Browsers list bubbles as windows too: Brave's translate popup and Firefox's untitled helper
    // windows have no close button.
    guard evidence.subrole == standardWindowSubrole, evidence.hasCloseButton else { return .auxiliary }
    guard let title = evidence.title, !title.isEmpty else { return .undetermined }
    return .normal
  }
}
