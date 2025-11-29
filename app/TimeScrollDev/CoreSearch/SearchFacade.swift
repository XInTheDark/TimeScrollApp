import Foundation
import AppKit

public struct SearchArgs {
    public var query: String?
    public var maxResults: Int
    public var includeImages: Bool
    /// Maximum pixel size for returned images' longest edge. If nil, implementations
    /// should use a sensible default (512).
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
    public let imagePNG: Data?
}

public enum SearchFacadeError: LocalizedError {
    case dbUnavailable(Error)
    
    public var errorDescription: String? {
        switch self {
        case .dbUnavailable(let underlying):
            return "Database unavailable: \(underlying.localizedDescription)"
        }
    }
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

    // Call this once after LA to ensure SQLCipher DB is open.
    public func openDatabaseOrThrow() throws {
        // Try to open via SQLCipherBridge with full error reporting
        do {
            try SQLCipherBridge.shared.openWithUnwrappedKeyOrThrow()
        } catch {
            throw SearchFacadeError.dbUnavailable(error)
        }
    }

    // MARK: - Vault/DB helpers (public)
    // Expose minimal helpers so the MCP server doesn’t need to import internal types.
    public func primeVaultIfPossible() {
        SQLCipherBridge.shared.openWithUnwrappedKeySilently()
        _ = try? DB.shared.openIfNeeded()
    }

    public func tryOpenDB() -> Bool {
        // Attempt SQLCipher open first (no-op if vault disabled or no key)
        SQLCipherBridge.shared.openWithUnwrappedKeySilently()
        // Prefer a positive indicator that an open happened
        if DB.shared.dbURL != nil { return true }
        // If vault disabled, plain open is allowed
        return (try? DB.shared.openIfNeeded()) != nil
    }

    public func unlockAndOpenIfNeeded() async -> (Bool, String?) {
        // Retry in case another process just unlocked
        if tryOpenDB() { return (true, nil) }
        // Prompt for LA in this process, then try SQLCipher open again
        do {
            // Use the new method that authenticates AND unwraps the key using the authenticated context
            let key = try await KeyStore.shared.authenticateAndUnwrapDbKey()
            
            // Mirror unlocked flag so helpers looking at defaults behave consistently
            let std = UserDefaults.standard
            std.set(true, forKey: "vault.isUnlocked")
            (UserDefaults(suiteName: StoragePaths.appGroupID) ?? .standard).set(true, forKey: "vault.isUnlocked")
            
            // Open with the unwrapped key
            SQLCipherBridge.shared.openWithKey(key)
        } catch {
            let msg = error.localizedDescription
            fputs("[SearchFacade] unlockAndOpenIfNeeded failed: \(msg)\n", stderr)
            return (false, msg)
        }
        
        if DB.shared.dbURL != nil || (try? DB.shared.openIfNeeded()) != nil {
            return (true, nil)
        } else {
            return (false, "Database open failed after unlock")
        }
    }

    public func run(_ a: SearchArgs, ocrLimit: Int = 50_000) async throws -> [RowOut] {
        do {
            try openDatabaseOrThrow()
        } catch {
            fputs("[SearchFacade] openDatabaseOrThrow failed: \(error.localizedDescription)\n", stderr)
            throw error
        }
        
        // Debug: Log DB path and count
        if let path = DB.shared.dbURL?.path {
            let count = (try? DB.shared.snapshotCount()) ?? -1
            fputs("[SearchFacade] DB path: \(path), snapshots: \(count)\n", stderr)
        } else {
            fputs("[SearchFacade] DB path is nil\n", stderr)
        }

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

        return rows.map { r in
            let ts = Self.isoF.string(from: Date(timeIntervalSince1970: TimeInterval(r.startedAtMs)/1000))
            let app = r.appName ?? r.appBundleId ?? "Unknown"
            // reasonably high OCR limit as requested
            let content = r.content.prefix(ocrLimit)
            var png: Data? = nil
            if a.includeImages {
                if let mp = a.imageMaxPixel {
                    png = Self.imagePNG(for: r, maxPixel: mp)
                } else {
                    png = Self.imagePNG(for: r)
                }
            }
            return RowOut(timeISO8601: ts, app: app, ocrText: String(content), imagePNG: png)
        }
    }

    // Lightweight diagnostics for MCP logging
    public func diagnostics() -> (path: String?, count: Int) {
        let p = DB.shared.dbURL?.path
        let c = (try? DB.shared.snapshotCount()) ?? -1
        return (p, c)
    }

    private static func imagePNG(for r: SearchResult, maxPixel: Int = 512) -> Data? {
        let url = URL(fileURLWithPath: r.path)
        let ext = url.pathExtension.lowercased()

        // HEVC segments or sealed videos
        if ["mov","mp4","tse"].contains(ext) {
            let img = HEVCFrameExtractor.image(forPath: url, startedAtMs: r.startedAtMs, format: "hevc", maxPixel: CGFloat(maxPixel))
            return img.flatMap { nsImageToPNG($0) }
        }

        // Prefer poster if present
        if let t = r.thumbPath {
            if let im = ThumbnailCache.shared.thumbnail(for: URL(fileURLWithPath: t), maxPixel: CGFloat(maxPixel)) {
                return nsImageToPNG(im)
            }
        }

        // Fallback: image file thumbnail
        if let im = ThumbnailCache.shared.thumbnail(for: url, maxPixel: CGFloat(maxPixel)) {
            return nsImageToPNG(im)
        }
        return nil
    }

    private static func nsImageToPNG(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
