import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpTitleCleanerTests {
  private let chrome = TimeWarpBrowserCatalog.browser(forBundleId: "com.google.Chrome")

  @Test func browserNameAndProfileAreRemoved() {
    #expect(TimeWarpTitleCleaner.pageTitle("Inbox - Google Chrome - Work", browser: chrome) == "Inbox")
    #expect(TimeWarpTitleCleaner.pageTitle("Inbox - Google Chrome", browser: chrome) == "Inbox")
  }

  @Test func titlesThatMentionTheBrowserEarlierKeepIt() {
    #expect(TimeWarpTitleCleaner.pageTitle("Google Chrome - Wikipedia - Google Chrome", browser: chrome) == "Google Chrome - Wikipedia")
  }

  @Test func groupNotesAndAddressesAreRemoved() {
    #expect(TimeWarpTitleCleaner.pageTitle("Docs - Part of group Work - Google Chrome", browser: chrome) == "Docs")
    #expect(TimeWarpTitleCleaner.pageTitle("Docs · https://example.com", browser: nil) == "Docs")
  }

  @Test func emptyTitlesAreNil() {
    #expect(TimeWarpTitleCleaner.pageTitle(nil, browser: chrome) == nil)
    #expect(TimeWarpTitleCleaner.pageTitle("   ", browser: chrome) == nil)
    #expect(TimeWarpTitleCleaner.pageTitle(" - Google Chrome", browser: chrome) == nil)
  }

  @Test func longTitlesAreClipped() {
    let title = TimeWarpTitleCleaner.pageTitle(String(repeating: "a", count: 1_000), browser: nil)
    #expect(title?.count == TimeWarpTitleCleaner.maxLength + 1)
    #expect(title?.hasSuffix("…") == true)
  }

  @Test func fileTitleIsTheName() {
    #expect(TimeWarpTitleCleaner.fileTitle(path: "/Users/me/Notes/plan.md") == "plan.md")
  }
}
