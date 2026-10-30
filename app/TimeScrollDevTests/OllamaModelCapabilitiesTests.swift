import Foundation
import Testing
@testable import TimeScroll

struct OllamaModelCapabilitiesTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "OllamaModelCapabilitiesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func parses_capabilities_from_show_payload() throws {
        let json = """
        { "details": { "family": "gemma4" }, "capabilities": ["embedding", "vision", "audio"] }
        """.data(using: .utf8)!
        let capabilities = OllamaModelCapabilities.parseCapabilities(from: json)
        #expect(capabilities == ["embedding", "vision", "audio"])
        #expect(OllamaModelCapabilities.supportsImageInput(capabilities ?? []))
    }

    @Test func text_only_models_do_not_support_images() throws {
        #expect(!OllamaModelCapabilities.supportsImageInput(["embedding"]))
        #expect(!OllamaModelCapabilities.supportsImageInput([]))
        let legacy = #"{ "details": { "family": "bert" } }"#.data(using: .utf8)!
        #expect(OllamaModelCapabilities.parseCapabilities(from: legacy) == nil)
    }

    @Test func refresh_caches_result_across_instances() throws {
        let defaults = isolatedDefaults()
        var fetchCount = 0
        let first = OllamaModelCapabilities(defaults: defaults) { _, _ in
            fetchCount += 1
            return ["embedding", "vision"]
        }
        #expect(first.refresh(model: "mm-embed", baseURL: "http://unit.test") == true)
        #expect(fetchCount == 1)

        let second = OllamaModelCapabilities(defaults: defaults) { _, _ in
            fetchCount += 1
            return nil
        }
        #expect(second.supportsImages(model: "mm-embed", baseURL: "http://unit.test"))
        #expect(fetchCount == 1)
    }

    @Test func unreachable_server_is_not_cached() throws {
        let defaults = isolatedDefaults()
        let capabilities = OllamaModelCapabilities(defaults: defaults) { _, _ in nil }
        #expect(capabilities.refresh(model: "offline-embed", baseURL: "http://unit.test") == nil)
        #expect(defaults.dictionary(forKey: "embedding.ollamaImageSupport") == nil)
    }

    @Test func parses_embed_response() throws {
        let json = #"{ "model": "m", "embeddings": [[0.5, -0.25, 1.0]] }"#.data(using: .utf8)!
        #expect(OllamaEmbeddingProvider.parseEmbedding(from: json) == [0.5, -0.25, 1.0])
        let error = #"{ "error": "model does not support images" }"#.data(using: .utf8)!
        #expect(OllamaEmbeddingProvider.parseEmbedding(from: error) == nil)
    }
}
