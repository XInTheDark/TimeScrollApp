import Foundation

enum MobileCLIPModelCatalog {
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/XInTheDark/MobileCLIP2-coreml/releases/latest")!

    enum Model: String, CaseIterable, Identifiable {
        case s0 = "MobileCLIP2-S0"
        case s2 = "MobileCLIP2-S2"
        case b = "MobileCLIP2-B"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .s0: return "S0"
            case .s2: return "S2"
            case .b: return "B"
            }
        }

        var subtitle: String {
            switch self {
            case .s0: return "Smallest"
            case .s2: return "Balanced"
            case .b: return "Highest quality"
            }
        }

        var assetFileName: String { "\(rawValue).zip" }

        var fallbackDownloadBytes: Int64 {
            switch self {
            case .s0: return 140_000_000
            case .s2: return 185_000_000
            case .b: return 300_000_000
            }
        }

        var preferredImageSize: Int {
            switch self {
            case .b: return 224
            case .s0, .s2: return 256
            }
        }

        var embeddingDimension: Int { 512 }
    }
}
