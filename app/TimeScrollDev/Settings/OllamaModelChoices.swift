import Foundation

/// Builds the Ollama model picker's entries from what the server listed and what is selected.
enum OllamaModelChoices {
    static let fallbackModel = "snowflake-arctic-embed:33m"

    /// The selected model is always offered, even when the server did not list it (Ollama down,
    /// model removed). A picker whose selection is missing from its entries renders blank.
    static func choices(listed: [String], selected: String) -> [String] {
        var out = listed.isEmpty ? [fallbackModel] : listed
        if !selected.isEmpty, !out.contains(selected) {
            out.append(selected)
        }
        return out
    }
}
