import SwiftUI
import AppKit

struct SearchResultsView: View {
    let query: String
    let appBundleIds: [String]?
    let startMs: Int64?
    let endMs: Int64?
    let captureKinds: [CaptureKind]?
    let audioSourceKinds: [AudioSourceKind]?
    let onOpen: (SearchResult, Int) -> Void
    let onClose: () -> Void

    @EnvironmentObject var settings: SettingsStore
    @State private var page: Int = 0
    @State private var rows: [SearchResultDisplayRow] = []
    @State private var isLoading: Bool = false
    @State private var hasNext: Bool = false
    @State private var useAI: Bool = false
    @State private var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "settings.searchViewMode") ?? "list") ?? .list
    @State private var requestToken: Int = 0

    private let pageSize: Int = 50
    private let search = SearchService()

    enum ViewMode: String {
        case list
        case tiles
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            resultsBody
            Divider()
            pager
        }
        .onAppear {
            useAI = settings.aiEmbeddingsEnabled && settings.aiModeOn
            loadPage(0)
        }
        .onChange(of: query) { _, _ in resetAndReload() }
        .onChange(of: appBundleIds) { _, _ in resetAndReload() }
        .onChange(of: startMs) { _, _ in resetAndReload() }
        .onChange(of: endMs) { _, _ in resetAndReload() }
        .onChange(of: captureKinds) { _, _ in resetAndReload() }
        .onChange(of: audioSourceKinds) { _, _ in resetAndReload() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trimmedQuery.isEmpty ? "Latest Captures" : "Search Results")
                    .font(.title3.weight(.semibold))
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Picker("View", selection: Binding(get: { viewMode }, set: { mode in
                    viewMode = mode
                    UserDefaults.standard.set(mode.rawValue, forKey: "settings.searchViewMode")
                })) {
                    Text("List").tag(ViewMode.list)
                    Text("Tiles").tag(ViewMode.tiles)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)

                Toggle("AI", isOn: Binding(get: { useAI }, set: { enabled in
                    useAI = enabled
                    UserDefaults.standard.set(enabled, forKey: "settings.aiModeOn")
                    resetAndReload()
                }))
                .toggleStyle(.switch)
                .disabled(!settings.aiEmbeddingsEnabled || EmbeddingService.shared.dim == 0)
                .help((settings.aiEmbeddingsEnabled && EmbeddingService.shared.dim > 0) ? "Use local embeddings for relevance" : "Enable AI search in Preferences first")

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close results")
                .accessibilityLabel("Close results")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultsBody: some View {
        ZStack {
            if rows.isEmpty && !isLoading {
                SearchEmptyStateView(query: trimmedQuery, useAI: useAI)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    if viewMode == .list {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(rows.enumerated()), id: \.1.id) { index, row in
                                Button {
                                    let absoluteIndex = page * pageSize + index
                                    onOpen(row.result, absoluteIndex)
                                } label: {
                                    SearchRowView(row: row)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                            ForEach(Array(rows.enumerated()), id: \.1.id) { index, row in
                                Button {
                                    let absoluteIndex = page * pageSize + index
                                    onOpen(row.result, absoluteIndex)
                                } label: {
                                    SearchTileView(row: row)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Loading results…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: viewMode)
    }

    private var pager: some View {
        HStack(spacing: 10) {
            Button {
                loadPage(page - 1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(page == 0 || isLoading)

            Text("Page \(page + 1)")
                .font(.subheadline.weight(.medium))

            if !rows.isEmpty {
                Text("• \(rows.count) shown")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                loadPage(page + 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(isLoading || !hasNext)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func resetAndReload() {
        page = 0
        loadPage(0)
    }

    private func loadPage(_ requestedPage: Int) {
        guard requestedPage >= 0 else { return }
        requestToken &+= 1
        let token = requestToken
        isLoading = true

        let offset = requestedPage * pageSize
        let limit = pageSize + 1
        let trimmed = trimmedQuery
        let fuzz = settings.fuzziness
        let ia = settings.intelligentAccuracy
        let aiEnabled = useAI && settings.aiEmbeddingsEnabled
        let apps = appBundleIds
        let start = startMs
        let end = endMs
        let captureKindsFilter = self.captureKinds
        let audioSourceKindsFilter = self.audioSourceKinds
        let searchService = search

        DispatchQueue.global(qos: .userInitiated).async {
            let fetched: [SearchResult]
            if trimmed.isEmpty {
                fetched = searchService.latestWithContent(
                    limit: limit,
                    offset: offset,
                    appBundleIds: apps,
                    startMs: start,
                    endMs: end,
                    captureKinds: captureKindsFilter,
                    audioSourceKinds: audioSourceKindsFilter
                )
            } else if aiEnabled {
                fetched = searchService.searchAI(
                    trimmed,
                    appBundleIds: apps,
                    startMs: start,
                    endMs: end,
                    captureKinds: captureKindsFilter,
                    audioSourceKinds: audioSourceKindsFilter,
                    limit: limit,
                    offset: offset
                )
            } else {
                fetched = searchService.searchWithContent(
                    trimmed,
                    fuzziness: fuzz,
                    intelligentAccuracy: ia,
                    appBundleIds: apps,
                    startMs: start,
                    endMs: end,
                    captureKinds: captureKindsFilter,
                    audioSourceKinds: audioSourceKindsFilter,
                    limit: limit,
                    offset: offset
                )
            }

            let preparedRows = Array(fetched.prefix(self.pageSize)).map {
                SearchResultDisplayRow(result: $0, query: trimmed, intelligentAccuracy: ia)
            }

            DispatchQueue.main.async {
                guard token == requestToken else { return }
                if requestedPage > 0 && fetched.isEmpty {
                    self.hasNext = false
                    self.isLoading = false
                    return
                }
                self.hasNext = fetched.count > self.pageSize
                self.rows = preparedRows
                self.page = requestedPage
                self.isLoading = false
            }
        }
    }
}

private struct SearchResultDisplayRow: Identifiable {
    let result: SearchResult
    let snippet: AttributedString?
    let fallbackSnippet: String

    var id: Int64 { result.id }

    init(result: SearchResult, query: String, intelligentAccuracy: Bool) {
        self.result = result
        let flattened = result.content.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        self.snippet = Self.makeSnippet(content: flattened, query: query, intelligentAccuracy: intelligentAccuracy)
        if flattened.isEmpty {
            self.fallbackSnippet = result.captureKind == .audio
                ? "No transcript available yet."
                : "No extracted text available."
        } else {
            self.fallbackSnippet = String(flattened.prefix(140))
        }
    }

    private static func normalize(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static func makeSnippet(content: String, query: String, intelligentAccuracy: Bool) -> AttributedString? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = SearchQueryParser.parse(trimmed).parts
        guard !parts.isEmpty else { return nil }

        let contentNorm = normalize(content)
        var firstHit: String.Index? = nil
        var firstLen = 0

        for part in parts {
            if part.isPhrase {
                let token = normalize(part.text)
                if let range = contentNorm.range(of: token) {
                    firstHit = range.lowerBound
                    firstLen = token.count
                    break
                }
            } else {
                let base = normalize(part.text)
                let variants: [String] = intelligentAccuracy ? OCRConfusion.expand(base) : [base]
                var found: Range<String.Index>? = nil
                for variant in variants {
                    if let range = contentNorm.range(of: variant) {
                        found = range
                        break
                    }
                }
                if let range = found {
                    firstHit = range.lowerBound
                    firstLen = contentNorm.distance(from: range.lowerBound, to: range.upperBound)
                    break
                }
            }
        }

        let snippet: String
        let baseRange: Range<String.Index>
        if let hit = firstHit {
            let utf16 = contentNorm.utf16
            let startPos = utf16.distance(from: utf16.startIndex, to: hit.samePosition(in: utf16) ?? utf16.startIndex)
            let origUTF16 = content.utf16
            let startIdx = origUTF16.index(origUTF16.startIndex, offsetBy: max(0, startPos))
            let start = startIdx.samePosition(in: content) ?? content.startIndex
            let startOffset = max(0, content.distance(from: content.startIndex, to: start) - 40)
            let snippetStart = content.index(content.startIndex, offsetBy: startOffset)
            let endOffset = min(content.count, startOffset + max(100, firstLen + 80))
            let snippetEnd = content.index(content.startIndex, offsetBy: endOffset)
            baseRange = snippetStart..<snippetEnd
            snippet = String(content[baseRange])
        } else {
            let endOffset = min(140, content.count)
            let snippetEnd = content.index(content.startIndex, offsetBy: endOffset)
            baseRange = content.startIndex..<snippetEnd
            snippet = String(content[baseRange])
        }

        var attributed = AttributedString(snippet)
        let snippetNorm = normalize(snippet)
        for part in parts {
            if part.isPhrase {
                let token = normalize(part.text)
                var searchStart = snippetNorm.startIndex
                while let range = snippetNorm.range(of: token, range: searchStart..<snippetNorm.endIndex) {
                    let upper = range.upperBound
                    if let attributedRange = Range(range, in: attributed) {
                        attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
                    }
                    searchStart = upper
                }
            } else {
                let base = normalize(part.text)
                let variants: [String] = intelligentAccuracy ? OCRConfusion.expand(base) : [base]
                for variant in variants {
                    var searchStart = snippetNorm.startIndex
                    while let range = snippetNorm.range(of: variant, range: searchStart..<snippetNorm.endIndex) {
                        let upper = range.upperBound
                        if let attributedRange = Range(range, in: attributed) {
                            attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
                        }
                        searchStart = upper
                    }
                }
            }
        }

        var combined = AttributedString(baseRange.lowerBound > content.startIndex ? "… " : "")
        combined += attributed
        combined += AttributedString(baseRange.upperBound < content.endIndex ? " …" : "")
        return combined
    }
}

private struct SearchRowView: View {
    let row: SearchResultDisplayRow
    @State private var isHovering: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SearchResultThumbnailView(row: row.result, maxPixel: 160, width: 136, height: 82)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    SearchResultIdentityIcon(row: row.result, size: 18, cornerRadius: 4)
                    Text(titleText)
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(dateString(ms: row.result.startedAtMs))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                SearchResultMetadataBadges(row: row.result)

                snippet
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                Label(URL(fileURLWithPath: row.result.path).lastPathComponent, systemImage: fileLabelSystemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundShape.fill(backgroundFill))
        .overlay(backgroundShape.stroke(backgroundStroke, lineWidth: 1))
        .shadow(color: isHovering ? Color.black.opacity(0.08) : .clear, radius: 10, y: 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var titleText: String {
        row.result.appName
        ?? row.result.audioSourceKind?.displayName
        ?? row.result.appBundleId
        ?? row.result.captureKind.displayName
    }

    private var fileLabelSystemImage: String {
        row.result.captureKind == .audio ? "waveform" : "doc.text"
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var backgroundFill: Color {
        isHovering
            ? Color.accentColor.opacity(0.10)
            : Color(nsColor: .controlBackgroundColor).opacity(0.60)
    }

    private var backgroundStroke: Color {
        isHovering
            ? Color.accentColor.opacity(0.22)
            : Color.primary.opacity(0.06)
    }

    private var snippet: Text {
        if let attributed = row.snippet {
            return Text(attributed)
        }
        return Text(row.fallbackSnippet).foregroundColor(.secondary)
    }

    private func dateString(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SearchTileView: View {
    let row: SearchResultDisplayRow
    @State private var isHovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchResultThumbnailView(row: row.result, maxPixel: 420)

            HStack(alignment: .center, spacing: 8) {
                SearchResultIdentityIcon(row: row.result, size: 16, cornerRadius: 4)
                Text(titleText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            SearchResultMetadataBadges(row: row.result)

            Text(dateString(ms: row.result.startedAtMs))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundShape.fill(backgroundFill))
        .overlay(backgroundShape.stroke(backgroundStroke, lineWidth: 1))
        .shadow(color: isHovering ? Color.black.opacity(0.08) : .clear, radius: 10, y: 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var titleText: String {
        row.result.appName
        ?? row.result.audioSourceKind?.displayName
        ?? row.result.appBundleId
        ?? row.result.captureKind.displayName
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var backgroundFill: Color {
        isHovering
            ? Color.accentColor.opacity(0.10)
            : Color(nsColor: .controlBackgroundColor).opacity(0.60)
    }

    private var backgroundStroke: Color {
        isHovering
            ? Color.accentColor.opacity(0.22)
            : Color.primary.opacity(0.06)
    }

    private func dateString(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SearchResultMetadataBadges: View {
    let row: SearchResult

    var body: some View {
        HStack(spacing: 8) {
            SearchResultBadge(title: row.captureKind.displayName, systemImage: row.captureKind.systemImage)
            if let source = row.audioSourceKind {
                SearchResultBadge(title: source.displayName, systemImage: source.systemImage)
            }
            if let durationMs = row.audioDurationMs {
                SearchResultBadge(title: durationString(ms: durationMs), systemImage: "clock")
            }
        }
    }

    private func durationString(ms: Int64) -> String {
        let totalSeconds = max(0, Int(ms / 1000))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct SearchResultBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

private struct SearchResultIdentityIcon: View {
    let row: SearchResult
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if row.captureKind == .audio {
            SearchResultSymbolIcon(symbolName: row.audioSourceKind?.systemImage ?? row.captureKind.systemImage,
                                   size: size,
                                   cornerRadius: cornerRadius,
                                   tint: .accentColor)
        } else if let bundleId = row.appBundleId {
            AppBundleIconView(bundleId: bundleId, size: size, cornerRadius: cornerRadius)
        } else {
            SearchResultSymbolIcon(symbolName: row.captureKind.systemImage,
                                   size: size,
                                   cornerRadius: cornerRadius,
                                   tint: .secondary)
        }
    }
}

private struct SearchResultSymbolIcon: View {
    let symbolName: String
    let size: CGFloat
    let cornerRadius: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: symbolName)
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

private struct AppBundleIconView: View {
    let bundleId: String
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var icon: NSImage? = nil
    @State private var requestedLoad = false

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear(perform: startLoadingIfNeeded)
    }

    private func startLoadingIfNeeded() {
        if let cached = AppIconCache.shared.cachedIcon(for: bundleId) {
            icon = cached
            return
        }

        guard !requestedLoad else { return }
        requestedLoad = true
        AppIconCache.shared.loadIconAsync(for: bundleId) { loaded in
            icon = loaded
        }
    }
}

private struct SearchResultThumbnailView: View {
    let row: SearchResult
    let maxPixel: Int
    var width: CGFloat? = nil
    var height: CGFloat? = nil

    @State private var loadedThumb: NSImage? = nil
    @State private var loadStarted: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))

            if row.captureKind == .audio {
                audioPlaceholder
            } else if let image = loadedThumb {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .scaleEffect(0.75)
            }
        }
        .frame(width: width, height: height)
        .aspectRatio((width != nil && height != nil) ? nil : 16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .onAppear(perform: startLoadingIfNeeded)
    }

    private var audioPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: row.audioSourceKind?.systemImage ?? row.captureKind.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(row.audioSourceKind?.shortDisplayName ?? row.captureKind.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startLoadingIfNeeded() {
        guard row.captureKind != .audio else { return }
        guard !loadStarted else { return }
        loadStarted = true

        let url = URL(fileURLWithPath: row.path)
        let ext = url.pathExtension.lowercased()
        let pixelSize = CGFloat(maxPixel)

        func assign(_ image: NSImage?) {
            guard let image else { return }
            DispatchQueue.main.async {
                loadedThumb = image
            }
        }

        func loadMainImage() {
            ThumbnailCache.shared.thumbnailAsync(for: url, maxPixel: pixelSize) { assign($0) }
        }

        func loadVideoFrame() {
            ThumbnailCache.shared.hevcThumbnail(for: url, startedAtMs: row.startedAtMs, maxPixel: pixelSize) { image in
                if let image {
                    assign(image)
                } else {
                    loadMainImage()
                }
            }
        }

        if let thumbPath = row.thumbPath {
            ThumbnailCache.shared.thumbnailAsync(for: URL(fileURLWithPath: thumbPath), maxPixel: pixelSize) { image in
                if let image {
                    assign(image)
                } else if ["mov", "mp4", "tse"].contains(ext) {
                    loadVideoFrame()
                } else {
                    loadMainImage()
                }
            }
            return
        }

        if ["mov", "mp4", "tse"].contains(ext) {
            loadVideoFrame()
            return
        }

        loadMainImage()
    }
}

private struct SearchEmptyStateView: View {
    let query: String
    let useAI: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text(query.isEmpty ? "No captures" : "No matches found")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }

    private var message: String {
        if query.isEmpty {
            return "Try broadening the date, app, or media filters to bring more captures into view."
        }
        if useAI {
            return "Try fewer keywords, a shorter phrase, or switch AI off for a stricter text match."
        }
        return "Try a broader term, a shorter phrase, or a different spelling."
    }
}
