import Foundation

/// Which web links Time Warp keeps: http and https pages, stored as the browser reported them.
enum TimeWarpLink {
  static let maxLength = 4_096

  /// Tab-suspender extensions replace a tab's address with their own page, carrying the real
  /// address after `uri=` in the fragment.
  static let suspendedPageMarker = "suspended.html"

  /// The link to store, or nil if it isn't a web page.
  static func storable(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
    if let unwrapped = unwrapSuspended(trimmed) { return storable(unwrapped) }
    guard var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          components.host?.isEmpty == false else { return nil }
    components.scheme = scheme
    return components.string
  }

  /// A short readable form for lists: host and path, without the query.
  static func displayText(_ link: String) -> String {
    guard let components = URLComponents(string: link), let host = components.host else { return link }
    let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let path = components.path == "/" ? "" : components.path
    let more = (components.query?.isEmpty == false) ? "?…" : ""
    return bareHost + path + more
  }

  private static func unwrapSuspended(_ link: String) -> String? {
    guard let components = URLComponents(string: link),
          let scheme = components.scheme?.lowercased(),
          scheme == "chrome-extension" || scheme == "moz-extension" || scheme == "safari-web-extension",
          components.path.hasSuffix(suspendedPageMarker),
          let fragment = components.fragment ?? components.query,
          let range = fragment.range(of: "uri=") else { return nil }
    let value = String(fragment[range.upperBound...])
    // Some extensions percent-encode the whole address; others store it as is, where decoding
    // would break escapes that belong to the address itself.
    let lower = value.lowercased()
    guard lower.hasPrefix("http%3a") || lower.hasPrefix("https%3a") else { return value }
    return value.removingPercentEncoding ?? value
  }
}
