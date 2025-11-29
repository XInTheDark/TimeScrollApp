import SwiftUI
import AppKit

struct SearchResultsView: View {
    let query: String
    let appBundleIds: [String]?
    let startMs: Int64?
    let endMs: Int64?
    let onOpen: (SearchResult, Int) -> Void
    let onClose: () -> Void

    @EnvironmentObject var settings: SettingsStore
    @State private var page: Int = 0
    @State private var rows: [SearchResult] = []
    @State private var isLoading: Bool = false
    @State private var hasNext: Bool = false
    @State private var useAI: Bool = false
    @State private var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "settings.searchViewMode") ?? "list") ?? .list
    @State private var requestToken: Int = 0

    private let pageSize: Int = 50

    enum ViewMode: String {
        case list, tiles
    }
    private let search = SearchService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            pager
        }
        .onAppear {
            // Initialize AI toggle from settings (optional feature)
            useAI = settings.aiEmbeddingsEnabled && settings.aiModeOn
            loadPage(0)
        }
        .onChange(of: query) { _ in resetAndReload() }
        .onChange(of: appBundleIds) { _ in resetAndReload() }
        .onChange(of: startMs) { _ in resetAndReload() }
        .onChange(of: endMs) { _ in resetAndReload() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Latest Snapshots" : "Results for \"\(query)\"")
                .font(.headline)
            Spacer()
            Picker("View", selection: Binding(get: { viewMode }, set: { mode in
                viewMode = mode
                UserDefaults.standard.set(mode.rawValue, forKey: "settings.searchViewMode")
            })) {
                Text("List").tag(ViewMode.list)
                Text("Tiles").tag(ViewMode.tiles)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Toggle("AI mode", isOn: Binding(get: { useAI }, set: { v in
                useAI = v
                UserDefaults.standard.set(v, forKey: "settings.aiModeOn")
                resetAndReload()
            }))
            .disabled(!settings.aiEmbeddingsEnabled || EmbeddingService.shared.dim == 0)
            .help((settings.aiEmbeddingsEnabled && EmbeddingService.shared.dim > 0) ? "Use local embeddings for relevance" : "Enable in Preferences or ensure NL embeddings available")
            Button("Close") { onClose() }
        }
        .padding(8)
    }

    private var list: some View {
        ZStack {
            ScrollView {
                if viewMode == .list {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if rows.isEmpty && !isLoading {
                            // Friendly placeholder instead of an empty pane
                            Text("No results")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                        // Use stable row identity so SwiftUI doesn't reuse previous-page state
                        ForEach(Array(rows.enumerated()), id: \.1.id) { (idx, row) in
                            Button(action: {
                                let absIndex = page * pageSize + idx
                                onOpen(row, absIndex)
                            }) {
                                SearchRowView(row: row, query: query)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color(NSColor.textBackgroundColor))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        if rows.isEmpty && !isLoading {
                            Text("No results")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                        // Use stable row identity so SwiftUI doesn't reuse previous-page state
                        ForEach(Array(rows.enumerated()), id: \.1.id) { (idx, row) in
                            Button(action: {
                                let absIndex = page * pageSize + idx
                                onOpen(row, absIndex)
                            }) {
                                SearchTileView(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Loading results…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .cornerRadius(10)
            }
        }
    }

    private var pager: some View {
        HStack {
            Button("Previous") { loadPage(page - 1) }
                .disabled(page == 0 || isLoading)
            Button("Next") { loadPage(page + 1) }
                .disabled(isLoading || !hasNext)
            Spacer()
            Text("Page \(page + 1)")
                .foregroundColor(.secondary)
        }
        .padding(8)
    }

    private func resetAndReload() {
        page = 0
        loadPage(0)
    }

    private func loadPage(_ p: Int) {
        guard p >= 0 else { return }
        // Bump token to invalidate any in-flight searches; only the latest response is applied.
        requestToken &+= 1
        let token = requestToken
        isLoading = true
        let offset = p * pageSize
        let limit = pageSize + 1
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let fuzz = settings.fuzziness
        let ia = settings.intelligentAccuracy
        let aiEnabled = useAI && settings.aiEmbeddingsEnabled
        let apps = appBundleIds
        let start = startMs
        let end = endMs
        let searchSvc = search

        // All searches run on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let fetched: [SearchResult]
            if trimmed.isEmpty {
                fetched = searchSvc.latestWithContent(limit: limit,
                                                       offset: offset,
                                                       appBundleIds: apps,
                                                       startMs: start,
                                                       endMs: end)
            } else if aiEnabled {
                fetched = searchSvc.searchAI(trimmed,
                                              appBundleIds: apps,
                                              startMs: start,
                                              endMs: end,
                                              limit: limit,
                                              offset: offset)
            } else {
                fetched = searchSvc.searchWithContent(trimmed,
                                                       fuzziness: fuzz,
                                                       intelligentAccuracy: ia,
                                                       appBundleIds: apps,
                                                       startMs: start,
                                                       endMs: end,
                                                       limit: limit,
                                                       offset: offset)
            }
            DispatchQueue.main.async {
                // Ignore stale responses from superseded searches
                guard token == requestToken else { return }
                if p > 0 && fetched.isEmpty {
                    self.hasNext = false
                    self.isLoading = false
                    return
                }
                self.hasNext = fetched.count > self.pageSize
                self.rows = Array(fetched.prefix(self.pageSize))
                self.page = p
                self.isLoading = false
            }
        }
    }
}

private struct SearchRowView: View {
    let row: SearchResult
    let query: String
    @State private var loadedThumb: NSImage? = nil
    @State private var loadStarted: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 4) {
                title
                snippet
                pathLine
            }
            Spacer()
        }
    }

    private var thumb: some View {
        // Return loaded thumbnail
        if let img = loadedThumb {
            return AnyView(Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 120, height: 72).cornerRadius(6))
        }
        // Start async load if not started
        if !loadStarted {
            DispatchQueue.main.async {
                guard !loadStarted else { return }
                loadStarted = true
                let url = URL(fileURLWithPath: row.path)
                let ext = url.pathExtension.lowercased()
                func loadMainImage() {
                    ThumbnailCache.shared.thumbnailAsync(for: url, maxPixel: 140) { img in
                        if let img = img { self.loadedThumb = img }
                    }
                }
                func loadVideoFrame() {
                    ThumbnailCache.shared.hevcThumbnail(for: url, startedAtMs: row.startedAtMs, maxPixel: 140) { img in
                        if let img = img { self.loadedThumb = img; return }
                        // Fallback to still image if HEVC frame failed
                        loadMainImage()
                    }
                }
                // Prefer poster thumbnail
                if let t = row.thumbPath {
                    ThumbnailCache.shared.thumbnailAsync(for: URL(fileURLWithPath: t), maxPixel: 140) { img in
                        if let img = img { self.loadedThumb = img; return }
                        // Poster missing; fall back to source
                        if ["mov","mp4","tse"].contains(ext) {
                            loadVideoFrame()
                        } else {
                            loadMainImage()
                        }
                    }
                    return
                }
                // Video: use HEVC extractor
                if ["mov","mp4","tse"].contains(ext) {
                    loadVideoFrame()
                    return
                }
                // Image: use async thumbnail
                loadMainImage()
            }
        }
        // Placeholder while loading
        return AnyView(Rectangle().fill(Color.gray.opacity(0.08)).overlay{ ProgressView().scaleEffect(0.6) }.frame(width: 120, height: 72).cornerRadius(6))
    }

    private var title: some View {
        HStack(spacing: 6) {
            if let bid = row.appBundleId, let icon = AppIconCache.shared.icon(for: bid) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .cornerRadius(3)
            }
            Text(row.appName ?? row.appBundleId ?? "Unknown App")
                .font(.subheadline).bold()
            Text(dateString(ms: row.startedAtMs))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var snippet: some View {
        // Flatten whitespace to keep rows compact
        let flat = row.content.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let attr = makeSnippet(content: flat, query: query)
        return Group {
            if let a = attr {
                Text(a)
            } else {
                Text(String(flat.prefix(120)))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var pathLine: some View {
        Text(URL(fileURLWithPath: row.path).lastPathComponent)
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private func dateString(ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Self.df.string(from: d)
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private func makeSnippet(content: String, query: String) -> AttributedString? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = SearchQueryParser.parse(q).parts
        let contentNorm = normalize(content)
        var firstHit: String.Index? = nil
        var firstLen = 0
        let intelligent = SettingsStore.shared.intelligentAccuracy
        // Find earliest occurrence of any token variant (phrases remain exact)
        for part in parts {
            if part.isPhrase {
                let tn = normalize(part.text)
                if let r = contentNorm.range(of: tn) {
                    firstHit = r.lowerBound
                    firstLen = tn.count
                    break
                }
            } else {
                let base = normalize(part.text)
                let variants: [String] = intelligent ? OCRConfusion.expand(base) : [base]
                var found: Range<String.Index>? = nil
                for v in variants {
                    if let r = contentNorm.range(of: v) { found = r; break }
                }
                if let r = found {
                    firstHit = r.lowerBound
                    firstLen = contentNorm.distance(from: r.lowerBound, to: r.upperBound)
                    break
                }
            }
        }
        // Window
        let snippet: String
        var baseRange: Range<String.Index>
        if let hit = firstHit {
            // Map index from normalized to original by using same UTF-16 positions
            let utf16 = contentNorm.utf16
            let startPos = utf16.distance(from: utf16.startIndex, to: hit.samePosition(in: utf16) ?? utf16.startIndex)
            let origUTF16 = content.utf16
            let startIdx = origUTF16.index(origUTF16.startIndex, offsetBy: max(0, startPos))
            let start = startIdx.samePosition(in: content) ?? content.startIndex
            let startOffset = max(0, content.distance(from: content.startIndex, to: start) - 40)
            let sIdx = content.index(content.startIndex, offsetBy: startOffset)
            let endOffset = min(content.count, startOffset + max(100, firstLen + 80))
            let eIdx = content.index(content.startIndex, offsetBy: endOffset)
            baseRange = sIdx..<eIdx
            snippet = String(content[baseRange])
        } else {
            let len = min(140, content.count)
            let eIdx = content.index(content.startIndex, offsetBy: len)
            baseRange = content.startIndex..<eIdx
            snippet = String(content[baseRange])
        }
        var attr = AttributedString(snippet)
        let snNorm = normalize(snippet)
        for part in parts {
            if part.isPhrase {
                let tn = normalize(part.text)
                var searchStart = snNorm.startIndex
                while let r = snNorm.range(of: tn, range: searchStart..<snNorm.endIndex) {
                    let hi = r.upperBound
                    if let ra = Range(r, in: attr) { attr[ra].inlinePresentationIntent = .stronglyEmphasized }
                    searchStart = hi
                }
            } else {
                let base = normalize(part.text)
                let variants: [String] = intelligent ? OCRConfusion.expand(base) : [base]
                for v in variants {
                    var searchStart = snNorm.startIndex
                    while let r = snNorm.range(of: v, range: searchStart..<snNorm.endIndex) {
                        let hi = r.upperBound
                        if let ra = Range(r, in: attr) { attr[ra].inlinePresentationIntent = .stronglyEmphasized }
                        searchStart = hi
                    }
                }
            }
        }
        // Ellipsize presentation
        var leading = ""
        var trailing = ""
        if baseRange.lowerBound > content.startIndex { leading = "… " }
        if baseRange.upperBound < content.endIndex { trailing = " …" }
        var combined = AttributedString(leading)
        combined += attr
        combined += AttributedString(trailing)
        return combined
    }
}

private struct SearchTileView: View {
    let row: SearchResult
    @State private var loadedThumb: NSImage? = nil
    @State private var loadStarted: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            thumb
            HStack(spacing: 6) {
                if let bid = row.appBundleId, let icon = AppIconCache.shared.icon(for: bid) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .cornerRadius(2)
                }
                Text(dateString(ms: row.startedAtMs))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }

    private var thumb: some View {
        // Return loaded thumbnail
        if let img = loadedThumb {
            return AnyView(Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).cornerRadius(6))
        }
        // Start async load if not started
        if !loadStarted {
            DispatchQueue.main.async {
                guard !loadStarted else { return }
                loadStarted = true
                let url = URL(fileURLWithPath: row.path)
                let ext = url.pathExtension.lowercased()
                func loadMainImage() {
                    ThumbnailCache.shared.thumbnailAsync(for: url, maxPixel: 400) { img in
                        if let img = img { self.loadedThumb = img }
                    }
                }
                func loadVideoFrame() {
                    ThumbnailCache.shared.hevcThumbnail(for: url, startedAtMs: row.startedAtMs, maxPixel: 400) { img in
                        if let img = img { self.loadedThumb = img; return }
                        loadMainImage()
                    }
                }
                // Prefer poster thumbnail
                if let t = row.thumbPath {
                    ThumbnailCache.shared.thumbnailAsync(for: URL(fileURLWithPath: t), maxPixel: 400) { img in
                        if let img = img { self.loadedThumb = img; return }
                        // Poster missing; fall back to source
                        if ["mov","mp4","tse"].contains(ext) {
                            loadVideoFrame()
                        } else {
                            loadMainImage()
                        }
                    }
                    return
                }
                // Video: use HEVC extractor
                if ["mov","mp4","tse"].contains(ext) {
                    loadVideoFrame()
                    return
                }
                // Image: use async thumbnail
                loadMainImage()
            }
        }
        // Placeholder while loading
        return AnyView(Rectangle().fill(Color.gray.opacity(0.08)).overlay{ ProgressView().scaleEffect(0.7) }.aspectRatio(16/10, contentMode: .fit).cornerRadius(6))
    }

    private func dateString(ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Self.df.string(from: d)
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
