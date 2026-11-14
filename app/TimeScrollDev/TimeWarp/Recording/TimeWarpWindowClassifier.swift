import ApplicationServices
import Foundation

/// Classifies browser windows as private or normal with the shared private-browsing rules. A
/// window's privacy never changes, so decided verdicts are remembered per window; Safari's address
/// field walk then runs once per window instead of on every navigation.
final class TimeWarpWindowClassifier {
  static let maxRemembered = 32

  private var remembered: [(window: AXUIElement, verdict: PrivateWindowVerdict)] = []

  func verdict(for facts: TimeWarpWindowFacts, profile: PrivateBrowsingProfile) -> PrivateWindowVerdict {
    if let known = remembered.first(where: { CFEqual($0.window, facts.element) }) { return known.verdict }
    var evidence = PrivateWindowEvidence(title: facts.title, subrole: facts.subrole, hasCloseButton: facts.hasCloseButton)
    if let rule = profile.addressField, !PrivateWindowClassifier.hasMarker(evidence, profile: profile) {
      evidence.addressFieldDescription = LivePrivateWindowEvidenceReader.addressFieldDescription(in: facts.element, rule: rule)
    }
    let verdict = PrivateWindowClassifier.verdict(for: evidence, profile: profile)
    // Undecided windows (no title yet) are asked again next time.
    if verdict == .normal || verdict == .privateWindow {
      if remembered.count >= Self.maxRemembered { remembered.removeFirst() }
      remembered.append((facts.element, verdict))
    }
    return verdict
  }

  func forgetAll() {
    remembered.removeAll()
  }
}
