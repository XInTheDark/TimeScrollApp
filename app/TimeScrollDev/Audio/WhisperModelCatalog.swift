import Foundation

struct WhisperModelDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let recommended: Bool
}

enum WhisperModelCatalog {
    static let descriptors: [WhisperModelDescriptor] = [
        WhisperModelDescriptor(id: "tiny", title: "Tiny", subtitle: "Fastest, lowest accuracy", recommended: false),
        WhisperModelDescriptor(id: "base", title: "Base", subtitle: "Balanced default for continuous capture", recommended: true),
        WhisperModelDescriptor(id: "small", title: "Small", subtitle: "Better accuracy, more memory", recommended: false),
        WhisperModelDescriptor(id: "medium", title: "Medium", subtitle: "Highest local quality before large models", recommended: false),
        WhisperModelDescriptor(id: "large-v3", title: "Large v3", subtitle: "Best quality, heaviest download", recommended: false),
    ]

    static func descriptor(for id: String) -> WhisperModelDescriptor? {
        descriptors.first(where: { $0.id == id })
    }
}
