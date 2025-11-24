import Testing
@testable import TimeScroll

struct EmbeddingServiceTests {
    @Test func parse_models_from_array_json() throws {
        let json = """
        [ { "name": "foo" }, { "name": "snowflake-arctic-embed:33m" }, { "id": "bar-id" } ]
        """.data(using: .utf8)!
        let parsed = EmbeddingService.OllamaEmbeddingProvider.parseModelsFromData(json)
        #expect(parsed.contains("foo"))
        #expect(parsed.contains("snowflake-arctic-embed:33m"))
        #expect(parsed.contains("bar-id"))
    }

    @Test func parse_models_from_object_field() throws {
        let json = """
        { "models": [ {"name": "alpha"}, {"name":"beta-embed"} ] }
        """.data(using: .utf8)!
        let parsed = EmbeddingService.OllamaEmbeddingProvider.parseModelsFromData(json)
        #expect(parsed.contains("alpha"))
        #expect(parsed.contains("beta-embed"))
    }

    @Test func reload_settings_applies_provider_and_model() async throws {
        let defaults = UserDefaults.standard
        defaults.set("ollama", forKey: "settings.embeddingProvider")
        defaults.set("test-model:1", forKey: "settings.embeddingModel")
        EmbeddingService.shared.reloadFromSettings()
        #expect(EmbeddingService.shared.providerID == "ollama")
        #expect(EmbeddingService.shared.modelID == "test-model:1")
    }

    @Test func parse_embedding_length_from_show_payload() throws {
        let json = """
        {
            "details": {
                "model_info": {
                    "bert.embedding_length": 384,
                    "general.embedding_length": 384
                }
            }
        }
        """.data(using: .utf8)!
        let length = EmbeddingService.OllamaEmbeddingProvider.parseEmbeddingLength(from: json)
        #expect(length == 384)
    }

    @Test func chunk_text_samples_and_limits() throws {
        // Make a long string (5000 chars) with simple content
        let long = String(repeating: "0123456789", count: 500)
        let chunks = EmbeddingService.chunkText(long, maxInput: 2000, overlapPct: 0.10, maxChunks: 10)
        #expect(chunks.count <= 10)
        // Each chunk should be at most maxInput length
        for c in chunks { #expect(c.count <= 2000) }

        // Ensure sampling selects middle portion when the source produces many windows
        let many = String(repeating: "x", count: 7000)
        let windows = EmbeddingService.chunkText(many, maxInput: 2000, overlapPct: 0.10, maxChunks: 5)
        #expect(windows.count == 5)
    }

    @Test func embed_long_text_averages_chunks() throws {
        // Only run this test if the NL provider is available.
        guard let nl = NLEmbeddingProvider() else { return }

        // Build a long text that will be chunked.
        let long = Array(repeating: "hello world ", count: 400).joined() // ~4400 chars
        let (vec, known, total) = EmbeddingService.embedLongTextWithStats(text: long, maxInput: 2000, maxChunks: 6, overlapPct: 0.10, provider: .appleNL, nlProvider: nl, ollamaProvider: nil)

        #expect(total > 0)
        #expect(known <= total)
        #expect(!vec.isEmpty)
        #expect(vec.count == nl.dim)
    }

    @Test func ollama_provider_persists_dims_between_sessions() throws {
        let defaults = UserDefaults.standard
        EmbeddingService.OllamaEmbeddingProvider.clearCachedDimsForTesting()
        defaults.removeObject(forKey: "embedding.ollamaDims")

        var fetchCount = 0
        let fetcher: EmbeddingService.OllamaEmbeddingProvider.MetadataFetcher = { _, _ in
            fetchCount += 1
            return 768
        }

        let first = EmbeddingService.OllamaEmbeddingProvider(model: "unit-model", baseURL: "http://unit.test", metadataFetcher: fetcher)
        #expect(first.dim == 768)
        #expect(fetchCount == 1)

        EmbeddingService.OllamaEmbeddingProvider.clearCachedDimsForTesting(preserveDefaults: true)
        fetchCount = 0

        let cached = EmbeddingService.OllamaEmbeddingProvider(model: "unit-model", baseURL: "http://unit.test", metadataFetcher: { model, baseURL in
            fetchCount += 1
            return nil
        })
        #expect(cached.dim == 768)
        #expect(fetchCount == 0)

        EmbeddingService.OllamaEmbeddingProvider.clearCachedDimsForTesting()
        defaults.removeObject(forKey: "embedding.ollamaDims")
    }
}
