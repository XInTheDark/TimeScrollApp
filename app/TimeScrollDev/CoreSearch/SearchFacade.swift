import Foundation
import AppKit

public struct SearchArgs {
    public var query: String?
    public var maxResults: Int
    public var includeImages: Bool
    /// Maximum pixel size for returned images' longest edge. If nil, implementations
    /// use `SearchFacade.defaultImageMaxPixel`.
    public var imageMaxPixel: Int?
    public var startMs: Int64?
    public var endMs: Int64?
    public var textOnly: Bool
    public var apps: [String]?
    public init(query: String?, maxResults: Int = 10, includeImages: Bool = false,
                startMs: Int64? = nil, endMs: Int64? = nil,
                 textOnly: Bool = true, apps: [String]? = nil, imageMaxPixel: Int? = nil) {
        self.query = query; self.maxResults = maxResults; self.includeImages = includeImages
        self.startMs = startMs; self.endMs = endMs; self.textOnly = textOnly; self.apps = apps
        self.imageMaxPixel = imageMaxPixel
    }
}

public struct RowOut {
    public let timeISO8601: String
    public let app: String
    public let ocrText: String
    /// JPEG-encoded snapshot image, when requested.
    public let imageJPEG: Data?
}

public final class SearchFacade {
    private let prefs: PreferencesService
    private static let tz = TimeZone(identifier: "Asia/Singapore")!
    private static let isoF: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = tz
        return f
    }()

    public init(prefs: PreferencesService = PreferencesService()) {
        self.prefs = prefs
    }

    public func run(_ a: SearchArgs, ocrLimit: Int = 50_000) async throws -> [RowOut] {
        let accessURL = StoragePaths.dbURL()
        guard let access = VaultMediaAccess.token(for: accessURL) else {
            throw NSError(domain: "TimeScroll.Vault", code: 1, userInfo: [NSLocalizedDescriptionKey: "Vault locked."])
        }
        // Runs inside the app, which opens the database for the current vault state.

        let limit = max(1, min(100, a.maxResults))
        let appIds = (a.apps?.isEmpty == false) ? a.apps : nil
        let trimmed = (a.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Resolve fuzziness enum (default .low)
        let fuzz: SettingsStore.Fuzziness = SettingsStore.Fuzziness(rawValue: prefs.fuzzinessRaw) ?? .low
        let ia = prefs.intelligentAccuracy

        // Fetch using SearchService (can run on any thread)
        let search = SearchService()
        let rows: [SearchResult]
        if trimmed.isEmpty {
            rows = search.latestWithContent(limit: limit, offset: 0,
                                            appBundleIds: appIds,
                                            startMs: a.startMs, endMs: a.endMs)
        } else if !a.textOnly, prefs.aiEmbeddingsEnabled, EmbeddingService.shared.dim > 0 {
            rows = search.searchAI(trimmed, appBundleIds: appIds,
                                   startMs: a.startMs, endMs: a.endMs,
                                   limit: limit, offset: 0)
        } else {
            rows = search.searchWithContent(trimmed, fuzziness: fuzz,
                                            intelligentAccuracy: ia,
                                            appBundleIds: appIds,
                                            startMs: a.startMs, endMs: a.endMs,
                                            limit: limit, offset: 0)
        }

        let results = rows.enumerated().map { index, r in
            let ts = Self.isoF.string(from: Date(timeIntervalSince1970: TimeInterval(r.startedAtMs)/1000))
            let app = r.appName ?? r.appBundleId ?? "Unknown"
            // reasonably high OCR limit as requested
            let content = r.content.prefix(ocrLimit)
            // Images are large in a model's context: cap their size and how many rows carry one.
            var jpeg: Data? = nil
            if a.includeImages, index < Self.maxImagesPerResponse {
                let maxPixel = min(Self.maxImageMaxPixel, max(Self.minImageMaxPixel, a.imageMaxPixel ?? Self.defaultImageMaxPixel))
                jpeg = Self.imageJPEG(for: r, maxPixel: maxPixel)
            }
            return RowOut(timeISO8601: ts, app: app, ocrText: String(content), imageJPEG: jpeg)
        }
        guard VaultMediaAccess.isCurrent(access, for: accessURL) else {
            throw NSError(domain: "TimeScroll.Vault", code: 1, userInfo: [NSLocalizedDescriptionKey: "Vault locked during search."])
        }
        return results
    }

    public static let defaultImageMaxPixel = 1024
    public static let minImageMaxPixel = 256
    public static let maxImageMaxPixel = 2048
    public static let maxImagesPerResponse = 10
    private static let jpegQuality = 0.7

    private static func imageJPEG(for r: SearchResult, maxPixel: Int) -> Data? {
        let url = URL(fileURLWithPath: r.path)
        let ext = url.pathExtension.lowercased()

        if ext == "tse", let header = try? FileCrypter.shared.peekTSEHeader(at: url), header.mime.hasPrefix("image/") {
            return ThumbnailCache.shared.thumbnail(for: url, maxPixel: CGFloat(maxPixel)).flatMap { nsImageToJPEG($0) }
        }

        // HEVC segments or sealed videos
        if ["mov","mp4","tse"].contains(ext) {
            let img = HEVCFrameExtractor.image(forPath: url, startedAtMs: r.startedAtMs, format: "hevc", maxPixel: CGFloat(maxPixel))
            return img.flatMap { nsImageToJPEG($0) }
        }

        // Prefer poster if present
        if let t = r.thumbPath {
            if let im = ThumbnailCache.shared.thumbnail(for: URL(fileURLWithPath: t), maxPixel: CGFloat(maxPixel)) {
                return nsImageToJPEG(im)
            }
        }

        // Fallback: image file thumbnail
        if let im = ThumbnailCache.shared.thumbnail(for: url, maxPixel: CGFloat(maxPixel)) {
            return nsImageToJPEG(im)
        }
        return nil
    }

    private static func nsImageToJPEG(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
