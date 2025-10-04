import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SnapshotStageView: View {
    @ObservedObject var model: TimelineModel
    var globalQuery: String = ""

    @State private var rects: [CGRect] = []
    @State private var localQuery: String = ""
    @State private var nsImage: NSImage? = nil

    var body: some View {
        ZStack { // center-aligned content by default
            if let sel = model.selected {
                let url = URL(fileURLWithPath: sel.path)
                let image: NSImage? = {
                    if url.pathExtension.lowercased() == "tse" {
                        // Only allow decrypt when vault is unlocked (regardless of vaultEnabled setting)
                        let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")
                        guard unlocked else { return nil }
                        if let data = try? FileCrypter.shared.decryptImage(at: url) {
                            return NSImage(data: data)
                        }
                        return nil
                    }
                    return nsImage ?? NSImage(contentsOf: url)
                }()
                if let image = image {
                    ZoomableImageView(image: image, rects: rects)
                        .id(model.selected?.id) // ensure NSViewRepresentable refreshes on selection change
                        .onAppear {
                            nsImage = image
                            refreshRects()
                        }
                        .onChange(of: model.selected?.id) { _ in
                            if let p = model.selected?.path {
                                let u = URL(fileURLWithPath: p)
                                if u.pathExtension.lowercased() == "tse" {
                                    let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")
                                    if unlocked {
                                        nsImage = (try? FileCrypter.shared.decryptImage(at: u)).flatMap { NSImage(data: $0) }
                                    } else {
                                        nsImage = nil
                                    }
                                } else {
                                    nsImage = NSImage(contentsOf: u)
                                }
                            } else {
                                nsImage = nil
                            }
                            rects = []
                            refreshRects()
                        }
                        .onChange(of: model.selectedIndex) { _ in
                            if let p = model.selected?.path {
                                let u = URL(fileURLWithPath: p)
                                if u.pathExtension.lowercased() == "tse" {
                                    let unlocked = UserDefaults.standard.bool(forKey: "vault.isUnlocked")
                                    if unlocked {
                                        nsImage = (try? FileCrypter.shared.decryptImage(at: u)).flatMap { NSImage(data: $0) }
                                    } else {
                                        nsImage = nil
                                    }
                                } else {
                                    nsImage = NSImage(contentsOf: u)
                                }
                            } else {
                                nsImage = nil
                            }
                            rects = []
                            refreshRects()
                        }
                } else {
                    Text("Failed to load image").foregroundColor(.secondary)
                }
            } else {
                Text("No snapshots").foregroundColor(.secondary)
            }

            // Center overlay with prev/time/next
            if model.selected != nil {
                CenterOverlay(model: model)
                    .allowsHitTesting(true)
            }

            // Actions menu (top-right)
            ActionsPanel(model: model,
                         localQuery: $localQuery,
                         onSubmitQuery: { refreshRects() },
                         onCopy: copyCurrent,
                         onSave: saveCurrent,
                         onReveal: revealCurrent,
                         onDelete: confirmAndDeleteCurrent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: globalQuery) { _ in
            refreshRects()
        }
        .onChange(of: localQuery) { _ in
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

    private func copyCurrent() { if let p = model.selected?.path { SnapshotActions.copyImage(at: URL(fileURLWithPath: p)) } }
    private func saveCurrent() { if let p = model.selected?.path { SnapshotActions.saveImageAs(from: URL(fileURLWithPath: p)) } }
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

private struct CenterOverlay: View {
    @ObservedObject var model: TimelineModel
    @State private var dragStartX: Double = 0
    @State private var dragStartY: Double = 0
    var body: some View {
        HStack(spacing: 12) {
            Button(action: { model.prev() }) {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.primary.opacity(model.selectedIndex + 1 < model.metas.count ? 0.95 : 0.35))
                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!(model.selectedIndex + 1 < model.metas.count))

            Text(model.selected.map { Self.df.string(from: Date(timeIntervalSince1970: TimeInterval($0.startedAtMs)/1000)) } ?? "")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.25))
                .cornerRadius(6)
                .foregroundColor(.white)
                .shadow(radius: 2)

            Button(action: { model.next() }) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.primary.opacity(model.selectedIndex - 1 >= 0 ? 0.95 : 0.35))
                    .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!(model.selectedIndex - 1 >= 0))
        }
        .padding(8)
        .background(Color.clear)
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
    let onCopy: () -> Void
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
                        Button("Copy Image") { onCopy() }
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
    static func copyImage(at url: URL) {
        let img: NSImage? = {
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

    static func saveImageAs(from url: URL) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Save Image As"
        if url.pathExtension.lowercased() == "tse" {
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
                if url.pathExtension.lowercased() == "tse" {
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
