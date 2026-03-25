import Foundation

struct MobileCLIPReleaseAsset: Identifiable, Equatable {
    let id: String
    let name: String
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String?
    let publishedAt: Date?

    var model: MobileCLIPModelCatalog.Model? {
        MobileCLIPModelCatalog.Model.allCases.first { $0.assetFileName == name }
    }
}

struct MobileCLIPLatestRelease: Equatable {
    let tagName: String
    let publishedAt: Date?
    let assets: [MobileCLIPReleaseAsset]

    func asset(for model: MobileCLIPModelCatalog.Model) -> MobileCLIPReleaseAsset? {
        assets.first { $0.model == model }
    }
}

enum MobileCLIPReleaseService {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func fetchLatestRelease() async throws -> MobileCLIPLatestRelease {
        let (data, response) = try await URLSession.shared.data(from: MobileCLIPModelCatalog.latestReleaseAPIURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "TimeScroll.MobileCLIP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load MobileCLIP2 release metadata"])
        }
        let payload = try decoder.decode(GitHubReleasePayload.self, from: data)
        return MobileCLIPLatestRelease(
            tagName: payload.tagName,
            publishedAt: payload.publishedAt,
            assets: payload.assets.map {
                MobileCLIPReleaseAsset(
                    id: String($0.id),
                    name: $0.name,
                    downloadURL: $0.browserDownloadURL,
                    byteCount: Int64($0.size),
                    sha256: $0.sha256Digest,
                    publishedAt: payload.publishedAt
                )
            }
        )
    }
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let publishedAt: Date?
    let assets: [GitHubAssetPayload]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubAssetPayload: Decodable {
    let id: Int64
    let name: String
    let size: Int64
    let digest: String?
    let browserDownloadURL: URL

    var sha256Digest: String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        if digest.hasPrefix(prefix) {
            return String(digest.dropFirst(prefix.count))
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case size
        case digest
        case browserDownloadURL = "browser_download_url"
    }
}
