import Foundation
import Testing
@testable import TimeScroll

@Suite(.serialized)
struct WhisperModelStoreTests {
  @Test func modelRequiresCoreMLArtifactsAndTokenizer() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WhisperModelStoreTests-\(UUID().uuidString)", isDirectory: true)
    let model = root.appendingPathComponent("model", isDirectory: true)
    let tokenizer = root.appendingPathComponent("tokenizer", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
    for artifact in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
      try FileManager.default.createDirectory(
        at: model.appendingPathComponent("\(artifact).mlmodelc", isDirectory: true),
        withIntermediateDirectories: true
      )
    }

    #expect(!WhisperModelStore.isReady(modelDirectory: model, tokenizerDirectories: [tokenizer]))

    let tokenizerURL = tokenizer.appendingPathComponent("tokenizer.json")
    try Data("{}".utf8).write(to: tokenizerURL)
    #expect(WhisperModelStore.isReady(modelDirectory: model, tokenizerDirectories: [tokenizer]))

    try FileManager.default.removeItem(at: model.appendingPathComponent("TextDecoder.mlmodelc"))
    #expect(!WhisperModelStore.isReady(modelDirectory: model, tokenizerDirectories: [tokenizer]))
  }
}
