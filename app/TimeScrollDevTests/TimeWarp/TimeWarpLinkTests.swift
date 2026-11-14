import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpLinkTests {
  private func keep(_ link: String) -> String? { TimeWarpLink.storable(link) }

  @Test func webLinksAreKeptAsIs() {
    #expect(keep("https://example.com/a/b?q=swift#top") == "https://example.com/a/b?q=swift#top")
    #expect(keep("https://www.youtube.com/watch?v=abc&t=42") == "https://www.youtube.com/watch?v=abc&t=42")
    #expect(keep("https://example.com/doc?id=5&token=abc") == "https://example.com/doc?id=5&token=abc")
    #expect(keep("  https://example.com/  ") == "https://example.com/")
  }

  @Test func otherSchemesAreDropped() {
    for link in ["file:///Users/me/a.txt", "chrome://settings", "about:blank", "javascript:alert(1)", "ftp://x.com", "data:text/html,hi", "https://"] {
      #expect(keep(link) == nil)
    }
  }

  @Test func suspendedTabsUnwrap() {
    let encoded = "chrome-extension://abc/suspended.html#ttl=Hi&uri=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1"
    #expect(keep(encoded) == "https://example.com/a?b=1")
    let plain = "chrome-extension://abc/suspended.html#ttl=Hi&uri=https://example.com/a%20b"
    #expect(keep(plain) == "https://example.com/a%20b")
    #expect(keep("chrome-extension://abc/suspended.html#uri=file:///etc/hosts") == nil)
  }

  @Test func overlongAndEmptyLinksAreDropped() {
    #expect(keep("") == nil)
    #expect(keep("   ") == nil)
    #expect(keep("https://example.com/" + String(repeating: "a", count: 5_000)) == nil)
  }

  @Test func schemeIsLowercased() {
    #expect(keep("HTTPS://Example.com/x") == "https://Example.com/x")
  }

  @Test func displayTextIsShort() {
    #expect(TimeWarpLink.displayText("https://www.example.com/a/b?q=1") == "example.com/a/b?…")
    #expect(TimeWarpLink.displayText("https://example.com/") == "example.com")
    #expect(TimeWarpLink.displayText("not a link") == "not a link")
  }
}
