import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SnapshotStageView: View {
    @ObservedObject var model: TimelineModel
    var globalQuery: String = ""

    @State private var rects: [CGRect] = []
    @State private var localQuery: String = ""
    @State private var nsImage: NSImage? = nil
    @State private var isLoading: Bool = false
    @State private var lastRequestedId: Int64 = 0
    @State private var loadToken: Int = 0
    @State private var showSpinner: Bool = false

    var body: some View {
        ZStack { // center-aligned content by default
            if let sel = model.selected {
                let _ = sel.path // silence unused warning after refactor
                if let image = nsImage {
                    ZoomableImageView(image: image, rects: rects)
                        .id(model.selected?.id) // ensure NSViewRepresentable refreshes on selection change
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.12), value: nsImage)
                        .onAppear {
                            refreshRects()
                        }
                        // Selection change handlers moved to outer container so they fire
                        // even when there is no current image.
                } else {
                    if showSpinner {
                        ProgressView("Preparing frame…")
                            .progressViewStyle(.linear)
                            .padding()
                    } else if isLoading {
                        // Avoid flicker: keep background empty while waiting for spinner or image
                        Color.clear
                    } else {
                        Text("No image").foregroundColor(.secondary)
                    }
                }
            } else {
                Text("No snapshots").foregroundColor(.secondary)
            }

            // Center overlay with prev/time/next
            if model.selected != nil {
                CenterOverlay(model: model, nsImage: nsImage)
                    .allowsHitTesting(true)
            }

            // Actions menu (top-right)
            ActionsPanel(model: model,
                         localQuery: $localQuery,
                         onSubmitQuery: { refreshRects() },
                         onCopyImage: copyCurrent,
                         onCopyText: copyCurrentText,
                         onSave: saveCurrent,
                         onReveal: revealCurrent,
                         onDelete: confirmAndDeleteCurrent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Debug overlay (top-left), visible only when Debug Mode is ON
            if SettingsStore.shared.debugMode, let s = model.selected {
                DebugOverlay(meta: s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: globalQuery) { _ in
            refreshRects()
        }
        .onChange(of: localQuery) { _ in
            refreshRects()
        }
        .onAppear { loadSelectedIfNeeded() }
        .onChange(of: model.selected?.id) { _ in
            loadSelectedIfNeeded()
            rects = []
            refreshRects()
        }
        .onChange(of: model.selectedIndex) { _ in
            loadSelectedIfNeeded()
            rects = []
            refreshRects()
        }
    }

    private func refreshRects() {
        guard SettingsStore.shared.showHighlights else { rects = []; return }
        guard let s = model.selected else { rects = []; return }
        // Local query overrides global when present
        let effective = localQuery.isEmpty ? globalQuery : localQuery
        let q = effective.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { rects = []; return }
        let parts = SearchQueryParser.parse(q).parts
        if parts.isEmpty {
            rects = []
            return
        }
        // Improved matching: fetch candidate boxes by contains, then filter by word boundaries
        // and length-aware fuzziness to avoid false positives like 'on' in 'button'.
        let fuzz = SettingsStore.shared.fuzziness
        func normalize(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }
    let intelligent = SettingsStore.shared.intelligentAccuracy
    let tokenNorms = parts.map { normalize($0.text) }.filter { !$0.isEmpty }

        func splitWords(_ s: String) -> [String] {
            let scalars = Array(s.unicodeScalars)
            var words: [String] = []
            var current = ""
            for u in scalars {
                if CharacterSet.alphanumerics.contains(u) {
                    current.unicodeScalars.append(u)
                } else if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { words.append(current) }
            return words
        }

        func editDistanceLE(_ a: String, _ b: String, max d: Int) -> Bool {
            if a == b { return true }
            let na = a.count, nb = b.count
            if abs(na - nb) > d { return false }
            // Optimized for small d (1-2). Use two rows.
            var prev = Array(0...nb)
            var cur = Array(repeating: 0, count: nb + 1)
            let xArr = Array(a)
            let yArr = Array(b)
            for i in 1...na {
                cur[0] = i
                let ac = xArr[i-1]
                var rowMin = cur[0]
                for j in 1...nb {
                    let cost = (ac == yArr[j-1]) ? 0 : 1
                    cur[j] = min(
                        prev[j] + 1,
                        cur[j-1] + 1,
                        prev[j-1] + cost
                    )
                    if cur[j] < rowMin { rowMin = cur[j] }
                }
                if rowMin > d { return false }
                swap(&prev, &cur)
            }
            return prev[nb] <= d
        }

        func matches(token t: String, inText boxText: String) -> Bool {
            let tn = t.count
            if tn == 0 { return false }
            let words = splitWords(boxText)
            if words.isEmpty { return false }
            let minPrefixLen: (Int) -> Int = { n in
                switch fuzz {
                case .off:
                    return n
                case .low:
                    return n <= 5 ? n : max(3, n - 1)
                case .medium:
                    return max(3, Int(ceil(Double(n) * 0.70)))
                case .high:
                    return max(3, Int(ceil(Double(n) * 0.60)))
                }
            }
            let maxEdits: Int = {
                switch fuzz {
                case .off: return 0
                case .low: return tn >= 6 ? 1 : 0
                case .medium: return 1
                case .high: return tn >= 8 ? 2 : 1
                }
            }()
            for w in words {
                let wn = w.count
                if tn <= 2 {
                    if w == t { return true }
                    continue
                }
                switch fuzz {
                case .off:
                    if w == t { return true }
                case .low:
                    if w == t { return true }
                    if wn >= tn, w.hasPrefix(t) { return true }
                    if maxEdits > 0, editDistanceLE(t, w, max: maxEdits) { return true }
                case .medium, .high:
                    let p = minPrefixLen(tn)
                    let pref = String(t.prefix(p))
                    if wn >= p, w.hasPrefix(pref) { return true }
                    if maxEdits > 0, editDistanceLE(t, w, max: maxEdits) { return true }
                }
            }
            return false
        }

        var all: [CGRect] = []
        if let rows = try? DB.shared.boxesWithText(for: s.id, matchingContains: nil) {
            for row in rows {
                let textNorm = normalize(row.text)
                for t in tokenNorms {
                    // Expand variants when intelligent accuracy is enabled; otherwise test the base token only
                    let variants = intelligent ? OCRConfusion.expand(t) : [t]
                    var ok = false
                    for v in variants {
                        if matches(token: v, inText: textNorm) { ok = true; break }
                    }
                    if ok {
                        all.append(row.rect)
                        break
                    }
                }
            }
        }
        // Deduplicate approximately (by rounding to 1e-3)
        var seen = Set<String>()
        rects = all.filter { r in
            let key = String(format: "%.3f_%.3f_%.3f_%.3f", r.origin.x, r.origin.y, r.size.width, r.size.height)
            if seen.contains(key) { return false }
            seen.insert(key); return true
        }
    }

    // MARK: - Image loading logic
    private func loadSelectedIfNeeded() {
        guard let s = model.selected else { nsImage = nil; isLoading = false; return }
        if lastRequestedId == s.id && nsImage != nil { return }
        lastRequestedId = s.id
        loadToken &+= 1
        let token = loadToken
        // 1) If we have a poster image (thumbPath), prefer it for instant UX
        if let t = s.thumbPath {
            let tu = URL(fileURLWithPath: t)
            if tu.pathExtension.lowercased() == "tse" {
                if let (hdr, data) = try? FileCrypter.shared.decryptTSE(at: tu), hdr.mime.hasPrefix("image/") {
                    withAnimation(.easeInOut(duration: 0.12)) { nsImage = NSImage(data: data) }
                    isLoading = false
                    showSpinner = false
                    return
                }
            } else if let im = NSImage(contentsOf: tu) {
                withAnimation(.easeInOut(duration: 0.12)) { nsImage = im }
                isLoading = false
                showSpinner = false
                return
            }
        }
        // 2) Begin background load with small retries for live segment flush
        // Do not clear nsImage here to avoid flicker; overlay spinner instead
        isLoading = true
        showSpinner = false
        let url = URL(fileURLWithPath: s.path)
        let ext = url.pathExtension.lowercased()
        var isVideo = ["mov","mp4"].contains(ext)
        if ext == "tse" {
            if let hdr = try? FileCrypter.shared.peekTSEHeader(at: url) {
                isVideo = hdr.mime.hasPrefix("video/")
            }
        }
        let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")

        func attemptLoad() -> NSImage? {
            if ext == "tse" {
                // Decide by cleartext header mime
                if let hdr = try? FileCrypter.shared.peekTSEHeader(at: url) {
                    if hdr.mime.hasPrefix("video/") {
                        return HEVCFrameExtractor.image(forPath: url, startedAtMs: s.startedAtMs, format: "hevc")
                    } else if hdr.mime.hasPrefix("image/"), unlocked,
                              let (_, data) = try? FileCrypter.shared.decryptTSE(at: url) {
                        return NSImage(data: data)
                    } else {
                        return nil
                    }
                }
            }
            if ["mov","mp4"].contains(ext) {
                return HEVCFrameExtractor.image(forPath: url, startedAtMs: s.startedAtMs, format: "hevc")
            }
            return NSImage(contentsOf: url)
        }

        // Delay the spinner by 0.2s to avoid flicker for very fast loads
        let spinnerToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if self.loadToken == spinnerToken && self.isLoading && self.nsImage == nil {
                withAnimation(.easeInOut(duration: 0.12)) { self.showSpinner = true }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var image: NSImage? = attemptLoad()
            if image == nil && isVideo {
                // Try a few short delays to allow a movie fragment to flush
                let delays: [UInt64] = [120_000_000, 280_000_000, 500_000_000] // ns
                for d in delays {
                    usleep(useconds_t(d / 1000))
                    image = attemptLoad()
                    if image != nil { break }
                }
            }
            DispatchQueue.main.async {
                // Ensure we are still showing the same load attempt
                guard self.loadToken == token else { return }
                if let im = image {
                    withAnimation(.easeInOut(duration: 0.12)) { self.nsImage = im }
                } // else keep the previous image to avoid flicker/flash
                self.isLoading = false
                withAnimation(.easeInOut(duration: 0.12)) { self.showSpinner = false }
            }
        }
    }

    private func copyCurrent() {
        if let p = model.selected?.path { SnapshotActions.copyImage(at: URL(fileURLWithPath: p), fallbackImage: nsImage) }
    }
    private func copyCurrentText() {
        if let id = model.selected?.id { SnapshotActions.copyText(snapshotId: id) }
    }
    private func saveCurrent() {
        if let p = model.selected?.path { SnapshotActions.saveImageAs(from: URL(fileURLWithPath: p), fallbackImage: nsImage) }
    }
    private func revealCurrent() { if let p = model.selected?.path { SnapshotActions.revealInFinder(URL(fileURLWithPath: p)) } }
    private func confirmAndDeleteCurrent() {
        guard let meta = model.selected else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Snapshot?"
        alert.informativeText = "This will permanently delete the selected snapshot from disk and remove it from the timeline."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteSnapshot(id: meta.id)
        }
    }
}

// MARK: - Debug Overlay
private struct DebugOverlay: View {
    let meta: SnapshotMeta

    private func fmtDate(_ ms: Int64, pattern: String) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return DebugOverlay.cachedFormatter(pattern: pattern).string(from: d)
    }

    private func segmentStart(from url: URL) -> Int64? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("seg-") else { return nil }
        let ts = String(name.dropFirst(4))
        let df = DebugOverlay.cachedFormatter(pattern: "yyyy-MM-dd-HH-mm-ss")
        if let d = df.date(from: ts) { return Int64(d.timeIntervalSince1970 * 1000) }
        return nil
    }

    var body: some View {
        let url = URL(fileURLWithPath: meta.path)
        let ext = url.pathExtension.lowercased()
        let mime: String? = (ext == "tse") ? (try? FileCrypter.shared.peekTSEHeader(at: url).mime) : nil
        let isVideo = ["mov","mp4"].contains(ext) || (mime?.hasPrefix("video/") ?? false)
        let segStart = isVideo ? (segmentStart(from: url) ?? 0) : 0
        let offset = isVideo ? max(0, meta.startedAtMs - segStart) : 0
        let liveMov = StoragePaths.videosDir().appendingPathComponent("seg-\(fmtDate(segStart, pattern: "yyyy-MM-dd-HH-mm-ss")).mov")
        let liveExists = FileManager.default.fileExists(atPath: liveMov.path)
        let sealedExists = FileManager.default.fileExists(atPath: url.path)

        let rows: [String] = {
            var r: [String] = []
            r.append("id: \(meta.id)")
            r.append("time: \(fmtDate(meta.startedAtMs, pattern: "HH:mm:ss.SSS")) (\(meta.startedAtMs))")
            if let app = meta.appName { r.append("app: \(app)") }
            r.append("path: \(url.lastPathComponent)")
            if isVideo {
                r.append("format: hevc (video)")
                r.append("segStart: \(fmtDate(segStart, pattern: "HH:mm:ss")) offsetMs=\(offset)")
                r.append("source: \(ext == "tse" ? (sealedExists ? "tse(sealed)" : (liveExists ? "mov(live)" : "(missing)")) : "mov(live)")")
            } else {
                if ext == "tse" && (mime?.hasPrefix("image/") ?? false) {
                    r.append("format: image (encrypted)")
                } else {
                    r.append("format: \(ext.isEmpty ? "(unknown)" : ext)")
                }
            }
            return r
        }()

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.self) { s in Text(s) }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.45))
        .foregroundColor(.white)
        .cornerRadius(6)
        .shadow(radius: 3)
    }

    private static var dfCache: [String: DateFormatter] = [:]
    private static func cachedFormatter(pattern: String) -> DateFormatter {
        if let f = dfCache[pattern] { return f }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern
        dfCache[pattern] = f
        return f
    }
}

private struct CenterOverlay: View {
    @ObservedObject var model: TimelineModel
    var nsImage: NSImage?
    @State private var dragStartX: Double = 0
    @State private var dragStartY: Double = 0

    /// Computes average brightness of the center region of the image (0.0 = dark, 1.0 = bright)
    private var centerBrightness: CGFloat {
        guard let image = nsImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0.5 // Default to middle brightness if no image
        }
        let w = cgImage.width
        let h = cgImage.height
        // Sample a central region (middle 30% of the image)
        let sampleW = max(1, w / 3)
        let sampleH = max(1, h / 6) // Just a strip in the vertical center
        let sampleX = (w - sampleW) / 2
        let sampleY = (h - sampleH) / 2
        let sampleRect = CGRect(x: sampleX, y: sampleY, width: sampleW, height: sampleH)
        guard let cropped = cgImage.cropping(to: sampleRect) else { return 0.5 }
        // Create a small bitmap to sample
        let pixelW = min(cropped.width, 100)
        let pixelH = min(cropped.height, 50)
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * pixelW
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * pixelH)
        guard let context = CGContext(
            data: &pixelData,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        // Calculate average luminance
        var totalLuminance: Double = 0
        let pixelCount = pixelW * pixelH
        for i in 0..<pixelCount {
            let offset = i * bytesPerPixel
            let r = Double(pixelData[offset]) / 255.0
            let g = Double(pixelData[offset + 1]) / 255.0
            let b = Double(pixelData[offset + 2]) / 255.0
            // Relative luminance formula
            totalLuminance += 0.299 * r + 0.587 * g + 0.114 * b
        }
        return CGFloat(totalLuminance / Double(pixelCount))
    }

    /// True if background is light (needs dark controls)
    private var isLightBackground: Bool {
        centerBrightness > 0.6
    }

    var body: some View {
        let containerBg: Color = isLightBackground ? Color.black.opacity(0.5) : Color.white.opacity(0.15)

        HStack(spacing: 12) {
            Button(action: { model.prev() }) {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(model.selectedIndex + 1 < model.metas.count ? 0.95 : 0.35))
            }
            .buttonStyle(.plain)
            .disabled(!(model.selectedIndex + 1 < model.metas.count))

            Text(model.selected.map { Self.df.string(from: Date(timeIntervalSince1970: TimeInterval($0.startedAtMs)/1000)) } ?? "")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            Button(action: { model.next() }) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(model.selectedIndex - 1 >= 0 ? 0.95 : 0.35))
            }
            .buttonStyle(.plain)
            .disabled(!(model.selectedIndex - 1 >= 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(containerBg)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: model.overlayOffsetX, y: model.overlayOffsetY)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                // Update live without committing to storage every tick
                if dragStartX == 0 && dragStartY == 0 {
                    dragStartX = model.overlayOffsetX
                    dragStartY = model.overlayOffsetY
                }
                model.overlayOffsetX = dragStartX + Double(v.translation.width)
                model.overlayOffsetY = dragStartY + Double(v.translation.height)
            }
            .onEnded { _ in
                dragStartX = 0; dragStartY = 0
            }
        )
    }

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
}

private struct ActionsPanel: View {
    @ObservedObject var model: TimelineModel
    @Binding var localQuery: String
    let onSubmitQuery: () -> Void
    let onCopyImage: () -> Void
    let onCopyText: () -> Void
    let onSave: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.actionPanelExpanded.toggle()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }

            if model.actionPanelExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Find in snapshot", text: $localQuery, onCommit: onSubmitQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    HStack(spacing: 8) {
                        Menu("Copy") {
                            Button("Copy Image") { onCopyImage() }
                            Button("Copy Text") { onCopyText() }
                        }
                        .fixedSize()
                        Button("Save…") { onSave() }
                        Button("Show in Finder") { onReveal() }
                        Button("Delete…") { onDelete() }
                            .keyboardShortcut(.delete)
                        if SettingsStore.shared.debugMode, let id = model.selected?.id {
                            Button("Copy Snapshot ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(String(id), forType: .string)
                            }
                        }
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .shadow(radius: 2)
            }
        }
        .padding(10)
    }
}

enum SnapshotActions {
    static func copyImage(at url: URL, fallbackImage: NSImage? = nil) {
        let img: NSImage? = {
            if let fb = fallbackImage { return fb }
            if url.pathExtension.lowercased() == "tse" {
                let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")
                if unlocked, let data = try? FileCrypter.shared.decryptImage(at: url) { return NSImage(data: data) }
                return nil
            }
            return NSImage(contentsOf: url)
        }()
        if let img = img {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        } else {
            NSSound.beep()
        }
    }

    static func copyText(snapshotId: Int64) {
        let text = (try? DB.shared.textContent(snapshotId: snapshotId)) ?? ""
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func saveImageAs(from url: URL, fallbackImage: NSImage? = nil) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Save Image As"
        if url.pathExtension.lowercased() == "tse" && fallbackImage == nil {
            // Suggest original extension (unknown here); default to .png
            panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".png"
            if #available(macOS 11.0, *) {
                panel.allowedContentTypes = [UTType.png, UTType.jpeg, UTType.heic]
            } else {
                panel.allowedFileTypes = ["png","jpg","jpeg","heic"]
            }
        } else {
            panel.nameFieldStringValue = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty {
                if #available(macOS 11.0, *) {
                    if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
                } else {
                    panel.allowedFileTypes = [ext]
                }
            }
        }
        if panel.runModal() == .OK, let dest = panel.url {
            do {
                if let fb = fallbackImage {
                    // Save the displayed image
                    if let t = dest.pathExtension.lowercased().isEmpty ? UTType.png : UTType(filenameExtension: dest.pathExtension), #available(macOS 11.0, *) {
                        guard let cg = fb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw NSError(domain: "TS.Save", code: -2) }
                        let uti = t.identifier as CFString
                        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, uti, 1, nil) else { throw NSError(domain: "TS.Save", code: -3) }
                        CGImageDestinationAddImage(dst, cg, nil)
                        if !CGImageDestinationFinalize(dst) { throw NSError(domain: "TS.Save", code: -4) }
                    } else {
                        // Fallback: PNG via NSBitmapImageRep
                        guard let tiff = fb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "TS.Save", code: -5) }
                        try data.write(to: dest, options: .atomic)
                    }
                } else if url.pathExtension.lowercased() == "tse" {
                    let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")
                    guard unlocked, let data = try? FileCrypter.shared.decryptImage(at: url) else {
                        throw NSError(domain: "TS.Save", code: -1)
                    }
                    try data.write(to: dest, options: Data.WritingOptions.atomic)
                } else {
                    let tmp = dest.deletingLastPathComponent().appendingPathComponent(".timescrolldev-tmp-\(UUID().uuidString)")
                    try FileManager.default.copyItem(at: url, to: tmp)
                    let _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
                }
            } catch {
                NSSound.beep()
            }
        }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
