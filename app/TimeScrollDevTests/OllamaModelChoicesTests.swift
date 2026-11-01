import Foundation
import Testing
@testable import TimeScroll

struct OllamaModelChoicesTests {
    @Test func lists_server_models_as_is() {
        let choices = OllamaModelChoices.choices(listed: ["a-embed", "b-embed"], selected: "b-embed")
        #expect(choices == ["a-embed", "b-embed"])
    }

    @Test func keeps_selected_model_when_server_did_not_list_it() {
        let choices = OllamaModelChoices.choices(listed: ["a-embed"], selected: "gone-embed")
        #expect(choices == ["a-embed", "gone-embed"])
    }

    @Test func unreachable_server_still_offers_the_selected_model() {
        let choices = OllamaModelChoices.choices(listed: [], selected: "embeddinggemma-2:440m")
        #expect(choices.contains("embeddinggemma-2:440m"))
        #expect(choices.contains(OllamaModelChoices.fallbackModel))
    }

    @Test func empty_selection_and_empty_list_offers_the_fallback_only() {
        #expect(OllamaModelChoices.choices(listed: [], selected: "") == [OllamaModelChoices.fallbackModel])
    }

    @Test func fallback_is_not_duplicated_when_selected() {
        let choices = OllamaModelChoices.choices(listed: [], selected: OllamaModelChoices.fallbackModel)
        #expect(choices == [OllamaModelChoices.fallbackModel])
    }
}
