import Foundation
import Testing
@testable import TimeScroll

struct TimeWarpDocumentFilterTests {
  @Test func localFilesAreKept() {
    #expect(TimeWarpDocumentFilter.path(fromDocument: "file:///Users/me/Notes/plan.md") == "/Users/me/Notes/plan.md")
    #expect(TimeWarpDocumentFilter.path(fromDocument: "file:///Users/me/My%20File.pdf") == "/Users/me/My File.pdf")
  }

  @Test func otherValuesAreDropped() {
    for value in ["", "https://example.com/", "/Users/me/plain-path.txt", "file:///", "not a url"] {
      #expect(TimeWarpDocumentFilter.path(fromDocument: value) == nil)
    }
  }

  @Test func systemAndAppBundleFilesAreDropped() {
    #expect(TimeWarpDocumentFilter.path(fromDocument: "file:///System/Library/x.plist") == nil)
    #expect(TimeWarpDocumentFilter.path(fromDocument: "file:///usr/share/man/a.1") == nil)
    #expect(TimeWarpDocumentFilter.path(fromDocument: "file:///Applications/Slack.app/Contents/Resources/app/index.html") == nil)
  }

  @Test func kindUsesTheDirectoryCheck() {
    #expect(TimeWarpDocumentFilter.kind(forPath: "/a", isDirectory: { _ in true }) == .folder)
    #expect(TimeWarpDocumentFilter.kind(forPath: "/a", isDirectory: { _ in false }) == .document)
    #expect(TimeWarpDocumentFilter.kind(forPath: "/a", isDirectory: { _ in nil }) == nil)
  }

  @Test func packagesAreDocuments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("twdoc-\(UUID().uuidString)")
    let package = root.appendingPathComponent("Slides.key")
    let folder = root.appendingPathComponent("Folder")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(TimeWarpDocumentFilter.liveIsDirectory(folder.path) == true)
    #expect(TimeWarpDocumentFilter.liveIsDirectory(package.path) == false)
    #expect(TimeWarpDocumentFilter.liveIsDirectory(root.appendingPathComponent("gone").path) == nil)
  }
}
