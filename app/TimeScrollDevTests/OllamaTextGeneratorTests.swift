import Foundation
import Testing
@testable import TimeScroll

struct OllamaTextGeneratorTests {
  private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

  @Test func cloudTagsAreRecognized() {
    #expect(OllamaTextGenerator.isCloudModelName("gemma4:cloud"))
    #expect(OllamaTextGenerator.isCloudModelName("gpt-oss:120b-cloud"))
    #expect(OllamaTextGenerator.isCloudModelName("GEMMA:CLOUD"))
    #expect(!OllamaTextGenerator.isCloudModelName("cloud"))
    #expect(!OllamaTextGenerator.isCloudModelName("cloud-writer:latest"))
    #expect(!OllamaTextGenerator.isCloudModelName("gemma4:latest"))
    #expect(!OllamaTextGenerator.isCloudModelName("gemma4"))
  }

  @Test func showResponseIsParsed() throws {
    let info = try #require(OllamaTextGenerator.parseModelInfo(json([
      "capabilities": ["completion", "vision"],
      "model_info": ["gemma3.context_length": 131_072, "gemma3.block_count": 26],
    ])))
    #expect(info == OllamaTextGenerator.ModelInfo(capabilities: ["completion", "vision"], contextTokens: 131_072, isRemote: false))
    #expect(OllamaTextGenerator.classify(info) == .ready(contextTokens: 131_072))
  }

  @Test func remoteModelsAreRefusedWhateverTheirName() throws {
    let host = try #require(OllamaTextGenerator.parseModelInfo(json(["capabilities": ["completion"], "remote_host": "https://ollama.com"])))
    #expect(OllamaTextGenerator.classify(host) == .cloudModelRefused)
    let model = try #require(OllamaTextGenerator.parseModelInfo(json(["capabilities": ["completion"], "remote_model": "gemma4"])))
    #expect(OllamaTextGenerator.classify(model) == .cloudModelRefused)
    let empty = try #require(OllamaTextGenerator.parseModelInfo(json(["capabilities": ["completion"], "remote_host": ""])))
    #expect(OllamaTextGenerator.classify(empty) == .ready(contextTokens: nil))
  }

  @Test func modelsThatDoNotReportTextGenerationAreUnsuitable() throws {
    let embedding = try #require(OllamaTextGenerator.parseModelInfo(json(["capabilities": ["embedding"]])))
    #expect(OllamaTextGenerator.classify(embedding) == .modelUnsuitable)
    let older = try #require(OllamaTextGenerator.parseModelInfo(json(["details": [:]])))
    #expect(OllamaTextGenerator.classify(older) == .modelUnsuitable)
    #expect(OllamaTextGenerator.parseModelInfo(Data("nope".utf8)) == nil)
  }

  @Test func payloadSetsContextAndUnloadsSoon() {
    let payload = OllamaTextGenerator.generatePayload(model: "m", system: "s", prompt: "p", contextTokens: 8_192, maxOutputTokens: 1_024, keepAlive: "1m", modelThinks: false)
    #expect(payload["stream"] as? Bool == false)
    #expect(payload["think"] == nil)
    #expect(payload["keep_alive"] as? String == "1m")
    let options = payload["options"] as? [String: Int]
    #expect(options?["num_ctx"] == 8_192)
    #expect(options?["num_predict"] == 1_024)
    #expect(payload["format"] != nil)
    #expect(JSONSerialization.isValidJSONObject(payload))
  }

  @Test func thinkingIsTurnedOffOnlyForModelsThatThink() {
    let payload = OllamaTextGenerator.generatePayload(model: "m", system: "s", prompt: "p", contextTokens: 8_192, maxOutputTokens: 1_024, keepAlive: "1m", modelThinks: true)
    #expect(payload["think"] as? Bool == false)
    #expect(OllamaTextGenerator.ModelInfo(capabilities: ["completion", "Thinking"], contextTokens: nil, isRemote: false).canThink)
    #expect(!OllamaTextGenerator.ModelInfo(capabilities: ["completion"], contextTokens: nil, isRemote: false).canThink)
  }

  @Test func onlyThinkingOutputCountsAsEmpty() {
    let data = Data(#"{"response":"","thinking":"We need to","done_reason":"length"}"#.utf8)
    #expect(OllamaTextGenerator.parseGeneratedText(data) == nil)
  }

  @Test func generatedTextIsTrimmedAndBadOutputIsRejected() {
    let answer = #"{"overview":"  done \n","topics":[]}"#
    #expect(OllamaTextGenerator.parseGeneratedText(json(["response": answer, "done_reason": "stop"])) == "done")
    #expect(OllamaTextGenerator.parseGeneratedText(json(["response": answer, "done_reason": "length"])) == nil)
    #expect(OllamaTextGenerator.parseGeneratedText(json(["response": #"{"overview":"   ","topics":[]}"#])) == nil)
    #expect(OllamaTextGenerator.parseGeneratedText(json(["response": "not json"])) == nil)
    #expect(OllamaTextGenerator.parseGeneratedText(json(["response": #"{"other":"x"}"#])) == nil)
    #expect(OllamaTextGenerator.parseGeneratedText(Data("nope".utf8)) == nil)
  }
}
