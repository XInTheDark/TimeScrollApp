import Foundation

struct MobileCLIPManifest: Decodable, Equatable {
    struct Artifact: Decodable, Equatable {
        let bytes: Int64
        let kind: String
        let path: String
    }

    struct Embedding: Decodable, Equatable {
        let contextLength: Int
        let dimension: Int
        let vocabSize: Int

        private enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case dimension
            case vocabSize = "vocab_size"
        }
    }

    struct ImagePreprocessing: Decodable, Equatable {
        let resize: Int
    }

    let artifacts: [Artifact]
    let embedding: Embedding
    let imagePreprocessing: ImagePreprocessing
    let minimumMacOS: Int
    let model: String

    private enum CodingKeys: String, CodingKey {
        case artifacts
        case embedding
        case imagePreprocessing = "image_preprocessing"
        case minimumMacOS = "minimum_macos"
        case model
    }

    func artifactPath(kind: String, relativeTo root: URL) -> URL? {
        guard let artifact = artifacts.first(where: { $0.kind == kind }) else { return nil }
        return root.appendingPathComponent(artifact.path)
    }
}

enum MobileCLIPManifestLoader {
    static func load(from bundleURL: URL) throws -> MobileCLIPManifest {
        let url = bundleURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MobileCLIPManifest.self, from: data)
    }
}
