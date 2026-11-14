import Foundation
import Testing
@testable import TimeScroll

final class TimeWarpOpenSafetyTests {
  private let root: URL
  private let editor = URL(fileURLWithPath: "/Applications/Editor.app")

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("twsafe-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  private func file(_ name: String, _ contents: String = "hello", executable: Bool = false) throws -> URL {
    let url = root.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    return url
  }

  private func check(_ kind: TimeWarpItemKind, _ path: String, app: String? = nil) -> TimeWarpOpenSafety.Verdict {
    let item = TimeWarpPlanItem(kind: kind, value: path, title: nil, appBundleId: app, frontMs: 0, visits: 0, lastSeenMs: 0, wasOpenAtEnd: false)
    return TimeWarpOpenSafety.check(item, appURL: { $0 == "com.editor" ? self.editor : nil })
  }

  @Test func webLinksMustBeHTTP() {
    #expect(check(.page, "https://example.com/") == .web(URL(string: "https://example.com/")!))
    #expect(check(.page, "file:///etc/passwd") == .refused)
    #expect(check(.page, "javascript:alert(1)") == .refused)
  }

  @Test func documentsOpenInTheirApp() throws {
    let text = try file("notes.txt")
    #expect(check(.document, text.path) == .file(text, app: nil))
    #expect(check(.document, text.path, app: "com.editor") == .file(text, app: editor))
  }

  @Test func missingFilesAreMissing() {
    #expect(check(.document, root.appendingPathComponent("gone.txt").path) == .missing)
    #expect(check(.app, "com.nothing") == .missing)
  }

  @Test func scriptsNeedTheAppTheyWereOpenIn() throws {
    let script = try file("run.sh", "#!/bin/sh\necho hi\n")
    #expect(check(.document, script.path) == .refused)
    #expect(check(.document, script.path, app: "com.editor") == .file(script, app: editor))
    let command = try file("x.command", "#!/bin/sh\n")
    #expect(check(.document, command.path) == .refused)
  }

  @Test func programsAreNeverLaunched() throws {
    let binary = try file("tool", "\u{7f}ELF", executable: true)
    #expect(check(.document, binary.path) == .refused)
    #expect(check(.document, binary.path, app: "com.editor") == .refused)
    let app = root.appendingPathComponent("Thing.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    #expect(check(.document, app.path, app: "com.editor") == .refused)
  }

  @Test func foldersOpen() {
    guard case let .folder(url) = check(.folder, root.path) else { Issue.record("expected a folder"); return }
    #expect(url.standardizedFileURL.path == root.standardizedFileURL.path)
  }

  @Test func warpPointsNeverOpen() {
    #expect(check(.warpPoint, "note") == .refused)
  }
}
